/// 拇指–食指捏合偵測。進入與放開使用不同閾值（遲滯），避免比例在邊界抖動時連續觸發。
public struct PinchDetector: Sendable {
    /// 捏合比例（`HandGeometry.pinchRatio`）低於此值視為捏合。
    public var enterRatio = 0.25
    /// 捏合後比例高於此值才視為放開。
    public var exitRatio = 0.40
    public private(set) var isPinched = false

    public init() {}

    /// 回傳 true 表示此幀開始捏合。偵測不到手（nil）時維持原狀態。
    public mutating func update(ratio: Double?) -> Bool {
        guard let ratio else { return false }
        if isPinched {
            if ratio > exitRatio { isPinched = false }
            return false
        }
        if ratio < enterRatio {
            isPinched = true
            return true
        }
        return false
    }
}

/// 喚醒手勢（張手 → 握拳）偵測：握拳須在最後一次張手後 `window` 秒內出現，單純舉手或握拳不會觸發。
public struct WakeDetector: Sendable {
    public var window = 1.0
    private var lastOpen: Double?

    public init() {}

    /// 回傳 true 表示此幀完成一次喚醒手勢。
    public mutating func update(pose: HandPose?, at t: Double) -> Bool {
        switch pose {
        case .open:
            lastOpen = t
        case .fist:
            if let lastOpen, t - lastOpen <= window {
                self.lastOpen = nil
                return true
            }
        case .other, nil:
            break
        }
        return false
    }
}
