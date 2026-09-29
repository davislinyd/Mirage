/// 操作者鎖定：喚醒後只跟著喚醒的那隻手。每一幀取離上一幀位置最近、而且在 `reach` 個校準掌寬以內的手；旁人的手
/// （或自己的另一隻手）離得遠，就不會被當成操作者，即使信心比較高。待命時還沒有操作者，用最可能的主要手
/// （`primary`），誰都可以喚醒。鎖定中看不到操作者時回傳 nil，由狀態機逾時回到待命。
public struct OperatorLock: Sendable {
    /// 校準掌寬：手快速移動時，每幀位移不到 0.2 掌寬；旁人的手通常在另一邊。
    public var reach = 2.5
    /// 操作者上一次出現的位置（像素）。
    private var last: Vec2?

    public init() {}

    /// `locked`：已喚醒或控制中；`palm`：校準掌寬（像素）。
    public mutating func select(_ hands: [Hand], width: Int, height: Int, palm: Double, locked: Bool) -> Hand? {
        guard locked, let last else {
            let hand = hands.primary
            last = hand.flatMap { Self.center($0, width: width, height: height) }
            return hand
        }
        let nearest = hands.compactMap { hand in Self.center(hand, width: width, height: height).map { (hand, $0) } }
            .min { $0.1.distance(to: last) < $1.1.distance(to: last) }
        guard let nearest, nearest.1.distance(to: last) <= reach * palm else { return nil }
        self.last = nearest.1
        return nearest.0
    }

    /// 看得到的關節的平均位置（像素）。
    static func center(_ hand: Hand, width: Int, height: Int) -> Vec2? {
        let seen = hand.joints.filter { $0.c >= HandGeometry.minConfidence }
        guard !seen.isEmpty else { return nil }
        let n = Double(seen.count)
        return Vec2(x: seen.reduce(0) { $0 + $1.x } / n * Double(width), y: seen.reduce(0) { $0 + $1.y } / n * Double(height))
    }
}
