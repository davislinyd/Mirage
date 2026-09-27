/// M0 引導流程的各階段，每個階段量測一項可行性風險。
public enum Phase: String, CaseIterable, Codable, Sendable {
    case warmup, latency, still, move, pinch, wake, daily

    /// 準備階段不計時：手連續入鏡 1 秒後才開始倒數，避免手還沒就定位就開始量測。
    public var duration: Double {
        switch self {
        case .warmup: 0
        case .latency: 32
        case .still: 5
        case .move, .pinch, .wake: 10
        case .daily: 15
        }
    }

    public var title: String {
        switch self {
        case .warmup: "準備"
        case .latency: "延遲比較"
        case .still: "靜止"
        case .move: "移動"
        case .pinch: "捏合"
        case .wake: "喚醒"
        case .daily: "日常"
        }
    }

    public var instruction: String {
        switch self {
        case .warmup: "把右手舉到鏡頭前，掌心朝向鏡頭；入鏡 1 秒後開始"
        case .latency: "伸出食指慢慢畫圈；相機會切換 4 種設定，骨架可能停頓一下"
        case .still: "伸出食指，保持不動"
        case .move: "先慢後快，在舒適範圍內移動食指"
        case .pinch: "拇指與食指捏合再放開，剛好 10 次"
        case .wake: "張手 → 握拳，剛好 5 次"
        case .daily: "自然動作：放下手、抓頭、喝水、打字"
        }
    }

    public static var totalDuration: Double {
        allCases.reduce(0) { $0 + $1.duration }
    }

    /// 依開始後經過的秒數回傳當前階段與剩餘秒數；流程結束回傳 nil。
    public static func at(elapsed: Double) -> (phase: Phase, remaining: Double)? {
        var end = 0.0
        for phase in allCases {
            end += phase.duration
            if elapsed < end { return (phase, end - elapsed) }
        }
        return nil
    }
}

/// 一幀的偵測結果。逐行寫入 JSONL，供離線調參與日後手勢回歸測試重播。
public struct FrameRecord: Codable, Sendable {
    /// 擷取時間（秒，capture session 時鐘）。
    public var t: Double
    public var phase: Phase
    public var width: Int
    public var height: Int
    /// 影格擷取 → 推論完成（ms）。
    public var latencyMs: Double
    /// Vision 推論耗時（ms）。
    public var inferenceMs: Double
    public var hands: [Hand]
    /// 延遲比較階段的相機設定代號；其他階段為 nil。
    public var config: String?

    public init(
        t: Double, phase: Phase, width: Int, height: Int, latencyMs: Double, inferenceMs: Double, hands: [Hand],
        config: String? = nil
    ) {
        self.t = t
        self.phase = phase
        self.width = width
        self.height = height
        self.latencyMs = latencyMs
        self.inferenceMs = inferenceMs
        self.hands = hands
        self.config = config
    }

    /// 主要操作手：優先右手，其次平均信心值最高者。
    public var primaryHand: Hand? {
        hands.max { a, b in
            (a.chirality == .right ? 1 : 0, a.meanConfidence) < (b.chirality == .right ? 1 : 0, b.meanConfidence)
        }
    }
}
