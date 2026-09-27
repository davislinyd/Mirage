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

    /// 食指根部到小指根部的距離，作為手部尺度。
    public var palmWidth: Double? {
        distance(.indexMCP, .littleMCP)
    }

    /// 拇指尖到食指尖的距離 ÷ 掌寬。
    public var pinchRatio: Double? {
        guard let gap = distance(.thumbTip, .indexTip), let palm = palmWidth, palm > 0 else { return nil }
        return gap / palm
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

    /// 食指指向（手指朝上）：食指尖比食指根部高出至少 `up` 個掌寬，其餘三指指尖不比各自根部高出 `down` 個掌寬。
    /// 不用手腕：手靠近鏡頭時手腕常在畫面外。`palmWidth` 由呼叫端提供，可沿用前幾幀量到的值。
    public func isPointing(palmWidth palm: Double, up: Double = 0.4, down: Double = 0.2) -> Bool? {
        func rise(_ tip: Joint, _ mcp: Joint) -> Double? {
            guard let t = normalized(tip), let m = normalized(mcp) else { return nil }
            return (t.y - m.y) * height / palm
        }
        guard palm > 0, let index = rise(.indexTip, .indexMCP), let middle = rise(.middleTip, .middleMCP),
              let ring = rise(.ringTip, .ringMCP), let little = rise(.littleTip, .littleMCP) else { return nil }
        return index >= up && middle <= down && ring <= down && little <= down
    }
}
