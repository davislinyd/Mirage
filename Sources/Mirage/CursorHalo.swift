import AppKit
import MirageCore
import QuartzCore

/// 游標周圍的光圈，讓使用者知道手勢狀態：喚醒後閃爍（手勢已辨識，伸出食指開始），控制中持續發光。
/// 是滑鼠事件穿透的透明小視窗，顯示期間每次螢幕更新都移到游標位置，所以跟著游標，不論游標是誰移動的。
@MainActor
final class CursorHalo: NSObject {
    private static let size = 64.0
    private let ring = CALayer()
    private lazy var window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size), styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        view.wantsLayer = true
        ring.frame = view.bounds.insetBy(dx: 12, dy: 12)
        ring.cornerRadius = ring.frame.width / 2
        ring.borderWidth = 3
        ring.borderColor = NSColor.systemCyan.cgColor
        ring.shadowColor = NSColor.systemCyan.cgColor
        ring.shadowOpacity = 1
        ring.shadowRadius = 6
        ring.shadowOffset = .zero
        view.layer?.addSublayer(ring)
        window.contentView = view
        return window
    }()
    private lazy var link: CADisplayLink = {
        let link = window.contentView!.displayLink(target: self, selector: #selector(follow))
        link.add(to: .main, forMode: .common)
        return link
    }()

    func show(_ state: ControlState) {
        ring.removeAllAnimations()
        switch state {
        case .idle:
            link.isPaused = true
            window.orderOut(nil)
            return
        case .armed:
            ring.backgroundColor = nil
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.2
            pulse.duration = 0.4
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            ring.add(pulse, forKey: "pulse")
        case .active:
            ring.backgroundColor = NSColor.systemCyan.withAlphaComponent(0.25).cgColor
        }
        follow()
        link.isPaused = false
        window.orderFrontRegardless()
    }

    @objc private func follow() {
        let mouse = NSEvent.mouseLocation
        let origin = NSPoint(x: mouse.x - Self.size / 2, y: mouse.y - Self.size / 2)
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }
}
