/// 拇指–食指捏合偵測。進入與放開使用不同閾值（遲滯），避免比例在邊界抖動時連續觸發。
public struct PinchDetector: Sendable {
    /// 捏合比例（`HandGeometry.pinchRatio`）低於此值視為捏合。兩次錄影中真正捏合的最小比例落在 0.07–0.28，
    /// 指向時從未低於 0.8。
    public var enterRatio = 0.30
    /// 捏合後比例高於此值才視為放開。
    public var exitRatio = 0.45
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

/// 點擊用的捏合：開始捏合後下一幀實際量到仍捏著，且兩幀都通過呼叫端的閘門（`valid`）才算一次點擊，
/// 單幀的比例誤判不會觸發。代價是多等一幀（約 33 ms）。
public struct PinchClickDetector: Sendable {
    private var pinch = PinchDetector()
    private var pending = false

    public var isPinched: Bool { pinch.isPinched }

    public init() {}

    /// 回傳 true 表示此幀確認一次點擊。
    public mutating func update(ratio: Double?, valid: Bool) -> Bool {
        let started = pinch.update(ratio: ratio)
        let confirmed = pending && ratio != nil && pinch.isPinched && valid
        pending = started && valid
        return confirmed
    }
}

/// 喚醒手勢（張手 → 握拳）偵測：張手維持 `hold` 秒後，`maxGap` 秒內轉為握拳並再維持 `hold` 秒才觸發。
/// 單純舉手、握拳，或放下手、拿東西時一閃而過的張手與握拳都不會觸發。張手期間與轉換途中 `maxGap` 內的
/// 其他姿勢不打斷（手指收攏要經過幾幀中間姿勢）；握拳期間容忍單幀雜訊。
public struct WakeDetector: Sendable {
    public var hold = 0.3
    public var maxGap = 0.3

    private enum Stage {
        case idle
        case open(since: Double, last: Double)
        case fist(since: Double)
    }

    private var stage = Stage.idle
    /// 目前這段握拳已容忍過一幀雜訊。
    private var glitched = false

    public init() {}

    /// 回傳 true 表示此幀完成一次喚醒手勢。偵測不到手（nil）視同雜訊。
    public mutating func update(pose: HandPose?, at t: Double) -> Bool {
        let pose = pose ?? .other
        switch (stage, pose) {
        case let (.open(since, _), .open):
            stage = .open(since: since, last: t)
        case let (.open(since, last), .fist) where last - since >= hold && t - last <= maxGap:
            stage = .fist(since: t)
        case let (.open(_, last), .other) where t - last <= maxGap:
            return false
        case let (.fist(since), .fist):
            if t - since >= hold {
                stage = .idle
                glitched = false
                return true
            }
        case (.fist, .other) where !glitched:
            glitched = true
            return false
        case (_, .open):
            stage = .open(since: t, last: t)
        default:
            stage = .idle
        }
        glitched = false
        return false
    }
}
