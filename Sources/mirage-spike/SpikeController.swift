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
            let capture = HandCapture(mapper: mapper) { [weak self] event in
                self?.handle(event)
            }
            do {
                camera = try capture.start()
            } catch {
                fail("相機啟動失敗：\(error)")
            }
            self.capture = capture
            print(camera)
            print("接下來依序有 \(Phase.allCases.count) 個階段，共約 \(Int(Phase.totalDuration)) 秒，照視窗提示做即可；關閉視窗會提前結束。")
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
            print("\n▶ \(phase.title)（\(Int(phase.duration)) 秒）：\(phase.instruction)")
        case .finished:
            writeResults()
            NSApp.terminate(nil)
        }
    }

    private func writeResults() {
        guard !resultsWritten, let capture else { return }
        resultsWritten = true
        let (frames, dropped) = capture.stop()
        let summary = Summary.text(
            camera: camera,
            dropped: dropped,
            reports: SpikeAnalysis.report(frames: frames, mapper: mapper)
        )
        print(summary)
        do {
            let url = try Summary.save(frames: frames, summary: summary)
            print("\n紀錄已存到 \(url.path)")
        } catch {
            print("\n寫入紀錄失敗：\(error)")
        }
    }

    private func showWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mirage M0"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    private func fail(_ message: String) -> Never {
        print(message)
        exit(1)
    }
}
