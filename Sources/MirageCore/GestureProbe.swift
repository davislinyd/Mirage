/// 單幀手勢量測結果（座標為螢幕 pt）。
public struct ProbeResult: Sendable {
    public var raw: Vec2?
    public var filtered: Vec2?
    public var isRight = false
    public var pinchRatio: Double?
    public var isPinched = false
    public var clicked = false
    public var woke = false
}

/// 主要手的食指尖 → 螢幕座標 → One Euro 濾波，並偵測點擊（捏合）與喚醒手勢。
/// 即時畫面與離線分析共用同一份邏輯，畫面上看到的與報告數字一致。
public struct GestureProbe: Sendable {
    /// 手消失超過此秒數後重置濾波器，避免游標從舊位置慢慢滑過去。
    public var resetGap = 0.2
    /// 掌寬須在基準的此範圍內才觸發手勢。側手、離太遠或太近的手，量到的掌寬會明顯偏離。
    public var palmRange = 0.6...1.4
    /// 靜止階段掌寬的中位數，作為使用者手部大小的基準（M1 改由校準取得）。
    public private(set) var baselinePalm: Double?
    private let mapper: ScreenMapper
    private var filter = OneEuroFilter2D()
    private var click = PinchClickDetector()
    private var wake = WakeDetector()
    private var lastSeen: Double?
    private var stillPalms: [Double] = []

    public init(mapper: ScreenMapper) {
        self.mapper = mapper
    }

    public mutating func update(_ frame: FrameRecord) -> ProbeResult {
        var result = ProbeResult()
        let geometry = frame.primaryHand.map { HandGeometry(hand: $0, width: frame.width, height: frame.height) }
        let palm = geometry?.palmWidth
        if frame.phase == .still {
            if let palm { stillPalms.append(palm) }
        } else if baselinePalm == nil {
            baselinePalm = SpikeAnalysis.percentile(stillPalms, 0.5)
        }
        let sized = baselinePalm.map { baseline in palm.map { palmRange.contains($0 / baseline) } ?? false } ?? true

        if let geometry {
            if let tip = geometry.normalized(.indexTip) {
                if let lastSeen, frame.t - lastSeen > resetGap { filter.reset() }
                lastSeen = frame.t
                let raw = mapper.map(tip)
                result.raw = raw
                result.filtered = filter(raw, at: frame.t)
            }
            result.isRight = geometry.hand.chirality == .right
            result.pinchRatio = geometry.pinchRatio
        }
        // 食指彎曲代表握拳或拿東西，不是捏合；關節不確定時不擋，以免漏掉真的捏合。
        result.clicked = click.update(ratio: result.pinchRatio, valid: sized && geometry?.indexCurled != true)
        result.isPinched = click.isPinched
        result.woke = wake.update(pose: sized ? geometry?.pose : .other, at: frame.t)
        return result
    }
}
