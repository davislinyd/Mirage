import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import MirageCore
import OSLog
import Synchronization

/// 選單列 App：狀態圖示與選單、全域快捷鍵與敲掌托、權限，以及螢幕鎖定與睡眠時暫停。
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let calibrationKey = "calibration"
    private static let knockImpactKey = "knockImpact"
    private static let knockMaxGapKey = "knockMaxGap"

    private lazy var tracker = HandTracker { [weak self] event in
        self?.handle(event)
    }
    private let panel = CalibrationPanel()
    private let halo = CursorHalo()
    private let hud = HUD()
    private var statusItem: NSStatusItem?
    private let stateItem = NSMenuItem()
    private let enableItem = NSMenuItem(title: "啟用（⌃⌥⌘M）", action: #selector(toggle), keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "允許輔助使用（移動游標需要）…", action: #selector(openAccessibility), keyEquivalent: "")
    private var hotKey: HotKey?
    /// 在掌托敲兩下切換啟用；停用時也在讀，才能敲回來。
    private var accelerometer: Accelerometer?
    /// 加速度計回呼在自己的 queue 上用，選單的滑桿在主執行緒改門檻。
    nonisolated private let knockDetector = Mutex(KnockDetector())
    /// 敲擊的滑桿；沒有加速度計時隱藏。
    private var knockItems: [NSMenuItem] = []
    private let cpuItem = NSMenuItem()
    /// 選單開著時每秒更新 `cpuItem`。
    private var cpuTimer: Timer?
    private var cpuSample = (cpu: 0.0, wall: 0.0)
    private var ready = false
    /// 相機無法使用的原因。
    private var problem: String?
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
        cpuItem.isEnabled = false
        let calibrateItem = NSMenuItem(title: "重新校準", action: #selector(recalibrate), keyEquivalent: "")
        for item in [enableItem, calibrateItem, accessibilityItem] {
            item.target = self
        }
        knockItems = knockSliders()
        // build 號是建置時間（scripts/build-app.sh），用來確認裝的是新版。
        let info = Bundle.main.infoDictionary
        let versionItem = NSMenuItem(
            title: "Mirage \(info?["CFBundleShortVersionString"] as? String ?? "?")（build \(info?["CFBundleVersion"] as? String ?? "?")）",
            action: nil, keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.items = [stateItem, .separator(), enableItem, calibrateItem, accessibilityItem, .separator()] + knockItems + [
            cpuItem, .separator(), versionItem,
            NSMenuItem(title: "結束 Mirage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = menu
        self.statusItem = statusItem

        hotKey = HotKey(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.toggle()
        }
        startKnocks()
        panel.onCancel = { [weak self] in
            self?.cancelCalibration()
        }
        observeSystem()
        calibration = UserDefaults.standard.data(forKey: Self.calibrationKey).flatMap {
            try? JSONDecoder().decode(Calibration.self, from: $0)
        }
        // 在相機就緒前設定：就緒前按了「重新校準」時，才不會被這裡蓋掉。
        tracker.use(calibration)
        // 沒有輔助使用權限時，系統會跳出提示並引導到系統設定。
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        refresh()

        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                report("沒有相機權限：到 System Settings → Privacy & Security → Camera 打開 Mirage，再重新開啟 Mirage。")
                return
            }
            do {
                try tracker.configure()
            } catch {
                report("相機啟動失敗：\(error)")
                return
            }
            ready = true
            // 換了相機格式或校準方式，舊的校準不適用。
            if let calibration, let size = tracker.frameSize,
               calibration.width != size.width || calibration.height != size.height || calibration.version != Calibration.currentVersion {
                self.calibration = nil
                tracker.use(nil)
            }
            if calibration == nil {
                recalibrate()
            } else {
                update()
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        accessibilityItem.isHidden = AXIsProcessTrusted()
    }

    func menuWillOpen(_ menu: NSMenu) {
        cpuItem.title = "Mirage CPU：量測中…"
        cpuSample = Self.cpuTime()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCPU() }
        }
        // 選單開著時 run loop 在 event tracking mode，只排在預設 mode 的 timer 不會觸發。
        RunLoop.main.add(timer, forMode: .common)
        cpuTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        cpuTimer?.invalidate()
        cpuTimer = nil
    }

    private func updateCPU() {
        let now = Self.cpuTime()
        cpuItem.title = String(format: "Mirage CPU：%.0f%%", (now.cpu - cpuSample.cpu) / (now.wall - cpuSample.wall) * 100)
        cpuSample = now
    }

    /// 這個行程用掉的 CPU 時間（user＋system）與經過時間，單位秒。兩者相除以一個核心為 100%，同活動監視器與 `top`。
    private static func cpuTime() -> (cpu: Double, wall: Double) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return (seconds(usage.ru_utime) + seconds(usage.ru_stime), ProcessInfo.processInfo.systemUptime)
    }

    /// 敲擊力道（`impact`）與兩下最長間隔（`maxGap`）。設定存在 UserDefaults，沒有時用 `KnockDetector` 的預設值。
    /// 力道下限 0.03 g：打字最高 0.026 g；0.04 g 以下還沒有錄影驗證。間隔下限 0.3 秒，要比 `minGap` 長。
    private func knockSliders() -> [NSMenuItem] {
        let defaults = UserDefaults.standard
        let impact = defaults.object(forKey: Self.knockImpactKey) as? Double ?? KnockDetector().impact
        let maxGap = defaults.object(forKey: Self.knockMaxGapKey) as? Double ?? KnockDetector().maxGap
        knockDetector.withLock {
            $0.impact = impact
            $0.maxGap = maxGap
        }
        let strength = MenuSlider(
            title: "敲擊力道", range: 0.03...0.12, step: 0.01, value: impact, ends: ("輕", "重"),
            format: { String(format: "%.2f g", $0) }
        ) { [weak self] value in
            self?.knockDetector.withLock { $0.impact = value }
            UserDefaults.standard.set(value, forKey: Self.knockImpactKey)
        }
        let gap = MenuSlider(
            title: "兩下最長間隔", range: 0.3...1.0, step: 0.05, value: maxGap, ends: ("快", "慢"),
            format: { String(format: "%.2f 秒", $0) }
        ) { [weak self] value in
            self?.knockDetector.withLock { $0.maxGap = value }
            UserDefaults.standard.set(value, forKey: Self.knockMaxGapKey)
        }
        return [strength.item, gap.item]
    }

    @objc private func toggle() {
        enabled.toggle()
        update()
    }

    /// 沒有加速度計（或系統更新後讀不到）時只記錄，快捷鍵照常。
    /// `log show --predicate 'subsystem == "io.github.davislinyd.Mirage" AND category == "knock"' --last 1h --style compact`
    private func startKnocks() {
        let log = Logger(subsystem: "io.github.davislinyd.Mirage", category: "knock")
        // 按鍵與觸控板點按（觸覺回饋）也會震機身。
        let inputs: [CGEventType] = [.keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        // 200 Hz：敲擊的振動頻率低，錄影降到 200 Hz 重播結果相同。
        let accelerometer = Accelerometer(interval: 5000) { [weak self] t, x, y, z in
            guard let self, let first = knockDetector.withLock({ $0.update(t: t, x: x, y: y, z: z) }) else { return }
            let idle = inputs.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min()!
            let lastInput = ProcessInfo.processInfo.systemUptime - idle
            guard knockDetector.withLock({ $0.accepts(first: first, lastInput: lastInput) }) else {
                log.notice("knock ignored: key or click \(first - lastInput, format: .fixed(precision: 2))s before")
                return
            }
            log.notice("knock")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.knocked() }
            }
        }
        do {
            try accelerometer.start()
            self.accelerometer = accelerometer
        } catch {
            log.error("accelerometer unavailable: \(String(describing: error), privacy: .public)")
            for item in knockItems { item.isHidden = true }
        }
    }

    private func knocked() {
        // 螢幕鎖定、睡眠時不切換。
        guard pauses.isEmpty else { return }
        toggle()
    }

    @objc private func recalibrate() {
        if let problem {
            panel.show(problem: problem)
            return
        }
        enabled = true
        calibrating = true
        panel.show(nil)
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
            halo.show(state)
        case .scrolling(let direction):
            halo.showScrolling(direction)
        case .mode(let mode):
            hud.show(mode)
        case .calibration(let progress):
            // 取消後仍可能收到幾幀已排隊的進度。
            guard calibrating else { return }
            panel.show(progress)
            if case .done(let result) = progress {
                calibrating = false
                calibration = result
                UserDefaults.standard.set(try? JSONEncoder().encode(result), forKey: Self.calibrationKey)
                // 完成訊息停留幾秒，讓使用者看完下一步再關閉；期間又開始校準就不關。
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    if !calibrating { panel.hide() }
                }
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
        if let problem { return ("exclamationmark.triangle", problem) }
        if !enabled { return ("hand.raised.slash", "已停用") }
        if !pauses.isEmpty { return ("hand.raised.slash", "已暫停：螢幕鎖定或睡眠") }
        if !ready { return ("hourglass", "正在啟動相機…") }
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

    /// 選單列 App 不在前景時，提示框（NSAlert）可能被系統藏起來，所以改顯示在選單列與校準視窗。
    private func report(_ problem: String) {
        self.problem = problem
        panel.show(problem: problem)
        refresh()
    }
}
