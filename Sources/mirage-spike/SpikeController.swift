import AppKit
import AVFoundation
import MirageCore

@MainActor
final class SpikeController: NSObject, NSApplicationDelegate {
    private let view = SkeletonView()
    private var window: NSWindow?
    private var capture: HandCapture?
    private var camera = ""
    private var mapper = ScreenMapper(screenWidth: 1440, screenHeight: 900)
    private var resultsWritten = false
    private let script: Script
    /// 指定的相機格式；nil 時同 App。
    private let size: (width: Int32, height: Int32)?

    init(script: Script, size: (width: Int32, height: Int32)?) {
        self.script = script
        self.size = size
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let size = NSScreen.main?.frame.size {
            mapper = ScreenMapper(screenWidth: size.width, screenHeight: size.height)
        }
        view.boxFraction = mapper.boxFraction
        showWindow()

        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                fail("沒有相機權限：到「系統設定 → 隱私權與安全性 → 相機」允許執行本工具的終端機 App，再重新執行。")
            }
            let capture = HandCapture(mapper: mapper, script: script) { [weak self] event in
                self?.handle(event)
            }
            do {
                camera = try capture.start(size: size)
            } catch {
                fail("相機啟動失敗：\(error)")
            }
            self.capture = capture
            print(camera)
            print("接下來依序有 \(script.phases.count) 個階段，共約 \(Int(script.totalDuration)) 秒，照視窗提示做即可；關閉視窗會提前結束。")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        writeResults()
    }

    private func handle(_ event: HandCapture.Event) {
        switch event {
        case .frame(let snapshot):
            view.snapshot = snapshot
        case .phase(let phase):
            let duration = phase.duration > 0 ? "（\(Int(phase.duration)) 秒）" : ""
            print("\n▶ \(phase.title)\(duration)：\(script.instruction(for: phase))")
        case .finished:
            writeResults()
            NSApp.terminate(nil)
        }
    }

    private func writeResults() {
        guard !resultsWritten, let capture else { return }
        resultsWritten = true
        let (frames, dropped, skipped) = capture.stop()
        let summary = Summary.text(
            script: script,
            camera: camera,
            dropped: dropped,
            skipped: skipped,
            reports: SpikeAnalysis.report(frames: frames, mapper: mapper),
            gaze: script.usesFace ? GazeAnalysis.report(frames: frames) : nil,
            depth: script.phases.contains(.push) ? DepthAnalysis.report(frames: frames) : nil
        )
        print(summary)
        do {
            let url = try Summary.save(frames: frames, summary: summary, script: script)
            print("\n紀錄已存到 \(url.path)")
        } catch {
            print("\n寫入紀錄失敗：\(error)")
        }
    }

    private func showWindow() {
        // 注視腳本全螢幕：點的位置要對應整個螢幕。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: script.usesFace ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mirage \(script.name)"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if script.usesFace {
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.toggleFullScreen(nil)
        }
        self.window = window
    }

    private func fail(_ message: String) -> Never {
        print(message)
        exit(1)
    }
}
