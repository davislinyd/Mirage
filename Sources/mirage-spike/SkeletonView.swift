import AppKit
import MirageCore

/// 一幀要畫的內容。座標皆為已鏡像的正規化座標（0...1，原點左下）。
struct SkeletonSnapshot: Sendable {
    /// 每隻手 21 個關節；信心不足為 nil。
    var hands: [[Vec2?]]
    var primary: Int?
    var cursor: Vec2?
    var pinched: Bool
    var phase: Phase
    var instruction: String
    /// 階段剩餘秒數；準備階段不計時，為 nil。
    var remaining: Double?
    /// 階段開始前的說明與倒數期間，距離開始的秒數。
    var startsIn: Double?
    var fps: Double
    var latencyMs: Double
}

/// 鏡像繪製手部骨架、感應區與濾波後的游標。不顯示相機畫面，省 GPU 也不露出環境。
final class SkeletonView: NSView {
    var snapshot: SkeletonSnapshot? {
        didSet { needsDisplay = true }
    }

    var boxFraction = 0.5

    private static let accent = NSColor(red: 0, green: 191.0 / 255, blue: 1, alpha: 1)
    private static let bones: [(Joint, Joint)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMCP), (.thumbMCP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP),
    ]

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        let origin = (1 - boxFraction) / 2
        Self.accent.withAlphaComponent(0.5).setStroke()
        NSBezierPath(rect: NSRect(
            x: bounds.width * origin, y: bounds.height * origin,
            width: bounds.width * boxFraction, height: bounds.height * boxFraction
        )).stroke()

        guard let snapshot else { return }
        for target in targets(snapshot) {
            NSColor.systemYellow.setStroke()
            let cross = NSBezierPath()
            cross.lineWidth = 2
            let p = point(target)
            cross.move(to: NSPoint(x: p.x - 10, y: p.y))
            cross.line(to: NSPoint(x: p.x + 10, y: p.y))
            cross.move(to: NSPoint(x: p.x, y: p.y - 10))
            cross.line(to: NSPoint(x: p.x, y: p.y + 10))
            cross.stroke()
            if GazeTargets.target(snapshot.phase, elapsed: 0) != nil {
                NSColor.systemYellow.setFill()
                NSBezierPath(ovalIn: circle(p, radius: 6)).fill()
            }
        }
        for (index, joints) in snapshot.hands.enumerated() {
            let color = index == snapshot.primary ? Self.accent : NSColor.gray
            color.set()
            let skeleton = NSBezierPath()
            skeleton.lineWidth = 2
            for (a, b) in Self.bones {
                guard let p = joints[a.rawValue], let q = joints[b.rawValue] else { continue }
                skeleton.move(to: point(p))
                skeleton.line(to: point(q))
            }
            skeleton.stroke()
            for joint in joints.compactMap({ $0 }) {
                NSBezierPath(ovalIn: circle(point(joint), radius: 3)).fill()
            }
        }

        if let cursor = snapshot.cursor {
            NSColor.white.set()
            let ring = NSBezierPath(ovalIn: circle(point(cursor), radius: 12))
            ring.lineWidth = 2
            // 捏合中填滿，即時確認捏合有沒有被偵測到。
            if snapshot.pinched {
                ring.fill()
            } else {
                ring.stroke()
            }
        }

        var countdown = snapshot.remaining.map { "・剩 \(Int($0.rounded(.up))) 秒" } ?? ""
        if let startsIn = snapshot.startsIn {
            let reading = startsIn - Script.countdown
            countdown = reading > 0 ? "・\(Int(reading.rounded(.up))) 秒後倒數" : "・即將開始"
            if reading <= 0 {
                let number = "\(Int(startsIn.rounded(.up)))" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 160, weight: .bold), .foregroundColor: NSColor.white,
                ]
                let size = number.size(withAttributes: attributes)
                number.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
            }
        }
        let text = """
        \(snapshot.phase.title)\(countdown)
        \(snapshot.instruction)
        \(Int(snapshot.fps.rounded())) fps・延遲 \(Int(snapshot.latencyMs.rounded())) ms
        """
        (text as NSString).draw(
            in: NSRect(x: 20, y: bounds.height - 110, width: bounds.width - 40, height: 100),
            withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .medium), .foregroundColor: NSColor.white]
        )
    }

    /// 懸停階段每 1/3 換一個十字；慢速對準階段同時顯示兩個；移過去點擊、右鍵時每 3 秒換一個。座標在感應區內。
    /// 注視階段的點以整個畫面為準：視窗全螢幕，與記錄的螢幕座標一致。
    private func targets(_ snapshot: SkeletonSnapshot) -> [Vec2] {
        let spots = [Vec2(x: 0.42, y: 0.5), Vec2(x: 0.58, y: 0.55), Vec2(x: 0.5, y: 0.42)]
        switch snapshot.phase {
        case .hover:
            let elapsed = snapshot.phase.duration - (snapshot.remaining ?? snapshot.phase.duration)
            return [spots[min(2, Int(elapsed / (snapshot.phase.duration / 3)))]]
        case .precise:
            return [Vec2(x: 0.46, y: 0.5), Vec2(x: 0.54, y: 0.5)]
        case .gazeCalibrate, .gazeCheck, .gazeHead:
            let elapsed = snapshot.phase.duration - (snapshot.remaining ?? snapshot.phase.duration)
            return GazeTargets.target(snapshot.phase, elapsed: elapsed).map { [$0] } ?? []
        case .moveAndTap, .moveAndTrigger:
            let jumps = [Vec2(x: 0.38, y: 0.6), Vec2(x: 0.62, y: 0.42), Vec2(x: 0.45, y: 0.4), Vec2(x: 0.6, y: 0.62)]
            let elapsed = snapshot.phase.duration - (snapshot.remaining ?? snapshot.phase.duration)
            return [jumps[Int(elapsed / 3) % jumps.count]]
        default:
            return []
        }
    }

    private func point(_ p: Vec2) -> NSPoint {
        NSPoint(x: p.x * bounds.width, y: p.y * bounds.height)
    }

    private func circle(_ center: NSPoint, radius: CGFloat) -> NSRect {
        NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}
