import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import MirageCore

/// 選單列 App：狀態圖示與選單、全域快捷鍵、權限，以及螢幕鎖定與睡眠時暫停。
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let calibrationKey = "calibration"

    private lazy var tracker = HandTracker { [weak self] event in
        self?.handle(event)
    }
    private let panel = CalibrationPanel()
    private var statusItem: NSStatusItem?
    private let stateItem = NSMenuItem()
    private let enableItem = NSMenuItem(title: "啟用（⌃⌥⌘M）", action: #selector(toggle), keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "允許輔助使用（移動游標需要）…", action: #selector(openAccessibility), keyEquivalent: "")
    private var hotKey: HotKey?
    private var ready = false
    private var enabled = true
    /// 暫停的原因（螢幕鎖定、睡眠等），全部解除才恢復。
    private var pauses: Set<String> = []
    private var calibrating = false
    private var calibration: Calibration?
    private var state = ControlState.idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        stateItem.isEnabled = false
        let calibrateItem = NSMenuItem(title: "重新校準", action: #selector(recalibrate), keyEquivalent: "")
        for item in [enableItem, calibrateItem, accessibilityItem] {
            item.target = self
        }
        menu.items = [
            stateItem, .separator(), enableItem, calibrateItem, accessibilityItem, .separator(),
            NSMenuItem(title: "結束 Mirage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = menu
        self.statusItem = statusItem

        hotKey = HotKey(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.toggle()
        }
        panel.onCancel = { [weak self] in
            self?.cancelCalibration()
        }
        observeSystem()
        calibration = UserDefaults.standard.data(forKey: Self.calibrationKey).flatMap {
            try? JSONDecoder().decode(Calibration.self, from: $0)
        }
        // 沒有輔助使用權限時，系統會跳出提示並引導到系統設定。
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        refresh()

        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                fail("Mirage 需要相機權限：到 System Settings → Privacy & Security → Camera 打開 Mirage，再重新開啟。")
            }
            do {
                try tracker.configure()
            } catch {
                fail("相機啟動失敗：\(error)")
            }
            ready = true
            if let calibration {
                tracker.use(calibration)
                update()
            } else {
                recalibrate()
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        accessibilityItem.isHidden = AXIsProcessTrusted()
    }

    @objc private func toggle() {
        enabled.toggle()
        update()
    }

    @objc private func recalibrate() {
        enabled = true
        calibrating = true
        panel.show(.collecting(remaining: CalibrationSession().duration))
        tracker.calibrate()
        update()
    }

    private func cancelCalibration() {
        guard calibrating else { return }
        calibrating = false
        tracker.use(calibration)
        update()
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func handle(_ event: HandTracker.Event) {
        switch event {
        case .state(let state):
            self.state = state
        case .calibration(let progress):
            // 取消後仍可能收到幾幀已排隊的進度。
            guard calibrating else { return }
            if case .done(let result) = progress {
                calibrating = false
                calibration = result
                UserDefaults.standard.set(try? JSONEncoder().encode(result), forKey: Self.calibrationKey)
                panel.hide()
            } else {
                panel.show(progress)
            }
        }
        refresh()
    }

    /// 依啟用、暫停與校準狀態開關相機（停用或暫停時關閉鏡頭），並更新選單列。
    private func update() {
        tracker.setRunning(ready && enabled && pauses.isEmpty && (calibrating || calibration != nil))
        refresh()
    }

    private func refresh() {
        let (symbol, text) = status
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mirage")
        stateItem.title = text
        enableItem.state = enabled ? .on : .off
    }

    /// 選單列圖示與狀態說明。
    private var status: (symbol: String, text: String) {
        if !enabled { return ("hand.raised.slash", "已停用") }
        if !pauses.isEmpty { return ("hand.raised.slash", "已暫停：螢幕鎖定或睡眠") }
        if calibrating { return ("scope", "校準中") }
        if calibration == nil { return ("hand.raised.slash", "尚未校準") }
        switch state {
        case .idle: return ("hand.raised", "待命：張手 → 握拳喚醒")
        case .armed: return ("hand.raised.fill", "已喚醒：3 秒內伸出食指開始控制")
        case .active: return ("hand.point.up.left.fill", "控制中")
        }
    }

    /// 螢幕鎖定、螢幕保護程式、睡眠、螢幕關閉、切換使用者時暫停；恢復後須重新喚醒。
    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, pause: "com.apple.screenIsLocked", resume: "com.apple.screenIsUnlocked")
        observe(distributed, pause: "com.apple.screensaver.didstart", resume: "com.apple.screensaver.didstop")
        observe(workspace, pause: NSWorkspace.willSleepNotification.rawValue, resume: NSWorkspace.didWakeNotification.rawValue)
        observe(
            workspace, pause: NSWorkspace.screensDidSleepNotification.rawValue,
            resume: NSWorkspace.screensDidWakeNotification.rawValue
        )
        observe(
            workspace, pause: NSWorkspace.sessionDidResignActiveNotification.rawValue,
            resume: NSWorkspace.sessionDidBecomeActiveNotification.rawValue
        )
    }

    private func observe(_ center: NotificationCenter, pause: String, resume: String) {
        _ = center.addObserver(forName: Notification.Name(pause), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(pause, true) }
        }
        _ = center.addObserver(forName: Notification.Name(resume), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(pause, false) }
        }
    }

    private func setPaused(_ reason: String, _ paused: Bool) {
        if paused {
            pauses.insert(reason)
        } else {
            pauses.remove(reason)
        }
        update()
    }

    private func fail(_ message: String) -> Never {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        exit(1)
    }
}
