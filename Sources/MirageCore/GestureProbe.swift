/// 單幀手勢量測結果（座標為螢幕 pt）。
public struct ProbeResult: Sendable {
    public var raw: Vec2?
    public var filtered: Vec2?
    public var isRight = false
    public var pinchRatio: Double?
    public var isPinched = false
    public var pinchStarted = false
    public var woke = false
}

/// 主要手的食指尖 → 螢幕座標 → One Euro 濾波，並偵測捏合與喚醒手勢。
/// 即時畫面與離線分析共用同一份邏輯，畫面上看到的與報告數字一致。
public struct GestureProbe: Sendable {
    /// 手消失超過此秒數後重置濾波器，避免游標從舊位置慢慢滑過去。
    public var resetGap = 0.2
    private let mapper: ScreenMapper
    private var filter = OneEuroFilter2D()
    private var pinch = PinchDetector()
    private var wake = WakeDetector()
    private var lastSeen: Double?

    public init(mapper: ScreenMapper) {
        self.mapper = mapper
    }

    public mutating func update(_ frame: FrameRecord) -> ProbeResult {
        var result = ProbeResult()
        guard let hand = frame.primaryHand else { return result }
        let geometry = HandGeometry(hand: hand, width: frame.width, height: frame.height)
        if let tip = geometry.normalized(.indexTip) {
            if let lastSeen, frame.t - lastSeen > resetGap { filter.reset() }
            lastSeen = frame.t
            let raw = mapper.map(tip)
            result.raw = raw
            result.filtered = filter(raw, at: frame.t)
        }
        result.isRight = hand.chirality == .right
        result.pinchRatio = geometry.pinchRatio
        result.pinchStarted = pinch.update(ratio: result.pinchRatio)
        result.isPinched = pinch.isPinched
        result.woke = wake.update(pose: geometry.pose, at: frame.t)
        return result
    }
}
