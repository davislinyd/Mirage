import AppKit
import MirageCore

/// 主螢幕右上角、選單列下方的狀態面板：只在控制中顯示目前的操作模式與可用的手勢。滑鼠事件穿透，不搶焦點。
@MainActor
final class HUD {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var mode: ControlMode?
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        icon.contentTintColor = .systemCyan
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        return panel
    }()

    /// nil 時隱藏。
    func show(_ mode: ControlMode?) {
        guard mode != self.mode else { return }
        self.mode = mode
        guard let mode else {
            panel.orderOut(nil)
            return
        }
        let (symbol, text) = Self.describe(mode)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        label.stringValue = text
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        // 游標對應的是主螢幕（有選單列的那一個）。
        if let screen = NSScreen.screens.first?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 12, y: screen.maxY - 12))
        }
        panel.orderFrontRegardless()
    }

    static func describe(_ mode: ControlMode) -> (symbol: String, text: String) {
        switch mode {
        case .pointing: ("hand.point.up.left.fill", "指向：按鍵點擊・扳機右鍵・按住扳機縮放")
        case .pressing: ("hand.tap.fill", "按住：移動手拖曳，伸直放開")
        case .scrolling(.still): ("arrow.up.and.down", scrolling)
        case .scrolling(.up): ("arrow.up", scrolling)
        case .scrolling(.down): ("arrow.down", scrolling)
        case .zooming: ("plus.magnifyingglass", "縮放：手往上放大、往下縮小")
        }
    }

    /// 捲動時文字不隨方向改變，面板寬度才不會跳動。
    private static let scrolling = "兩指捲動：指尖往上、往下甩，慢慢收回"
}
