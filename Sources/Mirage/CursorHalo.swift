import AppKit
import MirageCore
import QuartzCore

/// 游標周圍的光圈，讓使用者知道手勢狀態：喚醒後閃爍（手勢已辨識，伸出食指開始），控制中持續發光，捲動時光圈裡
/// 有兩根手指，捲動時往內容移動的方向滑動，沒在捲時靜止。
/// 是滑鼠事件穿透的透明小視窗，顯示期間每次螢幕更新都移到游標位置，所以跟著游標，不論游標是誰移動的。
@MainActor
final class CursorHalo: NSObject {
    private static let size = 64.0
    private let ring = CALayer()
    /// 游標尖端上方的手指，箭頭在尖端右下方，不會擋住。
    private let fingers = CALayer()
    private var direction: Scroller.Direction?
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
        fingers.frame = CGRect(x: 20, y: 33, width: 24, height: 12)
        for x in [3.0, 14.0] {
            let finger = CALayer()
            finger.frame = CGRect(x: x, y: 0, width: 7, height: 12)
            finger.cornerRadius = 3.5
            finger.backgroundColor = NSColor.systemCyan.cgColor
            fingers.addSublayer(finger)
        }
        fingers.isHidden = true
        view.layer?.addSublayer(fingers)
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
        showScrolling(nil)
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

    func showScrolling(_ direction: Scroller.Direction?) {
        guard direction != self.direction else { return }
        self.direction = direction
        fingers.removeAllAnimations()
        fingers.isHidden = direction == nil
        guard let direction, direction != .still else { return }
        // 只往一個方向滑並淡出，再從頭開始，才看得出方向。
        let slide = CABasicAnimation(keyPath: "position.y")
        slide.byValue = direction == .down ? -4.0 : 4.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0.2
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = 0.5
        group.repeatCount = .infinity
        fingers.add(group, forKey: "slide")
    }

    @objc private func follow() {
        let mouse = NSEvent.mouseLocation
        let origin = NSPoint(x: mouse.x - Self.size / 2, y: mouse.y - Self.size / 2)
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }
}
