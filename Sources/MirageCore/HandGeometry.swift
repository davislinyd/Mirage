import Foundation

public enum HandPose: Sendable, Equatable {
    case open, fist, other
}

/// 手部幾何量測。距離在像素空間計算（避免畫面長寬比失真），並以掌寬正規化，與手離鏡頭遠近無關。
public struct HandGeometry: Sendable {
    /// 低於此信心值的關節視為缺失。
    public static let minConfidence = 0.3

    public let hand: Hand
    public let width: Double
    public let height: Double

    public init(hand: Hand, width: Int, height: Int) {
        self.hand = hand
        self.width = Double(width)
        self.height = Double(height)
    }

    public func normalized(_ joint: Joint) -> Vec2? {
        let sample = hand[joint]
        return sample.c >= Self.minConfidence ? Vec2(x: sample.x, y: sample.y) : nil
    }

    public func distance(_ a: Joint, _ b: Joint) -> Double? {
        guard let p = normalized(a), let q = normalized(b) else { return nil }
        return Vec2(x: p.x * width, y: p.y * height).distance(to: Vec2(x: q.x * width, y: q.y * height))
    }

    /// 關節的像素座標。
    public func pixel(_ joint: Joint) -> Vec2? {
        normalized(joint).map { Vec2(x: $0.x * width, y: $0.y * height) }
    }

    /// 食指 PIP 與 DIP 兩個關節在畫面上的彎曲角度相加（度），伸直為 0。按鍵式點擊只彎這兩節。
    public var indexFlex: Double? {
        guard let m = pixel(.indexMCP), let p = pixel(.indexPIP), let d = pixel(.indexDIP), let t = pixel(.indexTip) else { return nil }
        func bend(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double {
            let u = Vec2(x: a.x - b.x, y: a.y - b.y), v = Vec2(x: c.x - b.x, y: c.y - b.y)
            let length = (u.x * u.x + u.y * u.y).squareRoot() * (v.x * v.x + v.y * v.y).squareRoot()
            guard length > 0 else { return 0 }
            return 180 - acos(max(-1, min(1, (u.x * v.x + u.y * v.y) / length))) * 180 / .pi
        }
        return bend(m, p, d) + bend(p, d, t)
    }

    /// 四個指根的中心（像素），代表手掌的位置。
    public var palmCenter: Vec2? {
        let knuckles = [Joint.indexMCP, .middleMCP, .ringMCP, .littleMCP].compactMap { pixel($0) }
        guard knuckles.count == 4 else { return nil }
        return Vec2(x: knuckles.reduce(0) { $0 + $1.x } / 4, y: knuckles.reduce(0) { $0 + $1.y } / 4)
    }

    /// 食指根部到小指根部的距離，作為手部尺度。
    public var palmWidth: Double? {
        distance(.indexMCP, .littleMCP)
    }

    /// 拇指尖到食指尖的距離 ÷ 掌寬。
    public var pinchRatio: Double? {
        guard let gap = distance(.thumbTip, .indexTip), let palm = palmWidth, palm > 0 else { return nil }
        return gap / palm
    }

    /// 五個指尖（含拇指）的位置（像素）與中心；任一指尖量不到為 nil。
    private var tips: (points: [Vec2], center: Vec2)? {
        let points = [Joint.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip].compactMap { pixel($0) }
        guard points.count == 5 else { return nil }
        return (points, Vec2(x: points.reduce(0) { $0 + $1.x } / 5, y: points.reduce(0) { $0 + $1.y } / 5))
    }

    /// 五個指尖到它們中心的最大距離 ÷ 掌寬：五指尖捏成一點時小。
    public var tipSpread: Double? {
        guard let tips, let palm = palmWidth, palm > 0, let far = tips.points.map({ $0.distance(to: tips.center) }).max() else { return nil }
        return far / palm
    }

    /// 四指（不含拇指）指尖比各自指根平均高出幾個掌寬：握拳時指尖收到指根下方。
    public var tipRise: Double? {
        let fingers: [(tip: Joint, mcp: Joint)] = [(.indexTip, .indexMCP), (.middleTip, .middleMCP), (.ringTip, .ringMCP), (.littleTip, .littleMCP)]
        let rises = fingers.compactMap { f in normalized(f.tip).flatMap { t in normalized(f.mcp).map { (t.y - $0.y) * height } } }
        guard rises.count == 4, let palm = palmWidth, palm > 0 else { return nil }
        return rises.reduce(0, +) / 4 / palm
    }

    /// 食指彎曲（指尖比 PIP 關節離手腕近）。握拳或拿杯子時拇指也會碰到食指，但食指是彎的。
    public var indexCurled: Bool? {
        guard let tip = distance(.indexTip, .wrist), let pip = distance(.indexPIP, .wrist) else { return nil }
        return tip <= pip
    }

    /// 四指（不含拇指）指尖比 PIP 關節離手腕遠視為伸直，否則視為彎曲；全伸直為張手，全彎曲為握拳。
    public var pose: HandPose {
        let fingers: [(tip: Joint, pip: Joint)] = [
            (.indexTip, .indexPIP), (.middleTip, .middlePIP), (.ringTip, .ringPIP), (.littleTip, .littlePIP),
        ]
        var extended = 0
        for finger in fingers {
            guard let tip = distance(finger.tip, .wrist), let pip = distance(finger.pip, .wrist) else { return .other }
            if tip > pip { extended += 1 }
        }
        switch extended {
        case fingers.count: return .open
        case 0: return .fist
        default: return .other
        }
    }

    /// 指向（手指朝上）：從食指起的 `fingers` 指（1 = 食指，2 = 食指與中指）指尖比各自根部高出至少 `up` 個掌寬，
    /// 其餘手指指尖不比各自根部高出 `down` 個掌寬。不用手腕：手靠近鏡頭時手腕常在畫面外。`palmWidth` 由呼叫端提供，
    /// 可沿用前幾幀量到的值。
    public func isPointing(palmWidth palm: Double, fingers: Int = 1, up: Double = 0.4, down: Double = 0.2) -> Bool? {
        func rise(_ tip: Joint, _ mcp: Joint) -> Double? {
            guard let t = normalized(tip), let m = normalized(mcp) else { return nil }
            return (t.y - m.y) * height / palm
        }
        guard palm > 0, let index = rise(.indexTip, .indexMCP), let middle = rise(.middleTip, .middleMCP),
              let ring = rise(.ringTip, .ringMCP), let little = rise(.littleTip, .littleMCP) else { return nil }
        let rises = [index, middle, ring, little]
        return rises.prefix(fingers).allSatisfy { $0 >= up } && rises.dropFirst(fingers).allSatisfy { $0 <= down }
    }
}
