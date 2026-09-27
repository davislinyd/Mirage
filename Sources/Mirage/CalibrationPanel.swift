import AppKit
import MirageCore

/// 校準視窗：說明、即時提示與剩餘秒數；相機無法使用時顯示原因。使用者關閉視窗即取消校準。
@MainActor
final class CalibrationPanel: NSObject, NSWindowDelegate {
    var onCancel: (() -> Void)?
    private let label = NSTextField(wrappingLabelWithString: "")
    /// 這次校準曾因範圍太小重來。
    private var retried = false
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 170), styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        panel.title = "Mirage 校準"
        panel.level = .floating
        // 選單列 App 平常不在前景：NSPanel 預設在 App 非作用中時隱藏，而 macOS 14 起 App 不能自行切到前景。
        // 使用者可能正在全螢幕的 App 裡，所以也允許顯示在全螢幕空間。
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        label.frame = NSRect(x: 20, y: 20, width: 380, height: 130)
        label.font = .systemFont(ofSize: 15)
        panel.contentView?.addSubview(label)
        return panel
    }()

    /// `progress` 為 nil 表示還沒收到鏡頭畫面。
    func show(_ progress: CalibrationSession.Progress?) {
        var lines = ["伸出食指、指尖朝上，其他手指收起，在舒適的範圍內慢慢畫大圈。"]
        switch progress {
        case nil:
            lines.append("等待鏡頭畫面…")
        case .collecting(_, .noHand):
            lines.append("看不到手：把手舉到鏡頭前，手掌朝向鏡頭。")
        case .collecting(_, .notPointing):
            lines.append("看到手了，但不是食指朝上：伸直食指，其他手指收起。")
        case .collecting(let remaining, .pointing):
            lines.append(String(format: "很好，繼續畫圈：剩 %.1f 秒", remaining))
        case .tooSmall:
            retried = true
        case .done:
            break
        }
        if retried { lines.append("範圍太小，已重新開始，請畫大一點的圈。") }
        display(lines.joined(separator: "\n"))
    }

    /// 顯示相機無法使用的原因。
    func show(problem: String) {
        display(problem)
    }

    private func display(_ text: String) {
        label.stringValue = text
        if !panel.isVisible {
            panel.center()
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        retried = false
        panel.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        retried = false
        onCancel?()
    }
}
