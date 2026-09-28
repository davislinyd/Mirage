/// 錄影的各階段。M0 引導流程的每個階段量測一項可行性風險；手勢腳本錄下候選手勢，供重播調參。
public enum Phase: String, CaseIterable, Codable, Sendable {
    case warmup, latency, still, move, pinch, wake, daily
    case trigger, triggerHold, twoFingerTrigger, halfBend, reverseBend, fist
    case hover, precise, sweep, tap, tapHold
    case moveAndTap, moveAndTrigger, threeFingerBend

    /// 準備階段不計時：手連續入鏡 1 秒後才開始倒數，避免手還沒就定位就開始量測。
    public var duration: Double {
        switch self {
        case .warmup: 0
        case .latency: 32
        case .still: 5
        case .move, .pinch, .wake, .hover, .precise: 10
        case .sweep: 8
        case .moveAndTap, .moveAndTrigger: 18
        case .triggerHold, .halfBend, .fist, .tapHold: 12
        case .daily, .trigger, .twoFingerTrigger, .reverseBend, .tap, .threeFingerBend: 15
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
        case .trigger: "扳機點擊"
        case .triggerHold: "扳機按住"
        case .twoFingerTrigger: "兩指扳機"
        case .halfBend: "半彎捲動"
        case .reverseBend: "反向捲動"
        case .fist: "握拳"
        case .hover: "懸停"
        case .precise: "慢速對準"
        case .sweep: "快速移動"
        case .tap: "按鍵點擊"
        case .tapHold: "按鍵按住"
        case .moveAndTap: "移過去點擊"
        case .moveAndTrigger: "移過去右鍵"
        case .threeFingerBend: "三指捲動"
        }
    }

    public var instruction: String {
        switch self {
        case .warmup: "把右手舉到鏡頭前，掌心朝向鏡頭；入鏡 1 秒後開始"
        case .latency: "伸出食指慢慢畫圈"
        case .still: "伸出食指，保持不動"
        case .move: "先慢後快，在舒適範圍內移動食指"
        case .pinch: "拇指與食指捏合再放開，剛好 10 次"
        case .wake: "張手 → 握拳，剛好 5 次"
        case .daily: "自然動作：放下手、抓頭、喝水、打字"
        case .trigger: "伸出食指、拇指豎起（比手槍），拇指往下壓到食指側面再抬起，10 次；食指盡量不動"
        case .triggerHold: "同上，拇指壓住約 1 秒再抬起，5 次"
        case .twoFingerTrigger: "食指與中指伸直、拇指豎起，拇指往下壓到食指側面再抬起，10 次"
        case .halfBend: "食指與中指伸直，像平常捲動一樣彎一半再伸直，10 下"
        case .reverseBend: "食指與中指彎一半停約 1 秒，再伸直一下、彎回原處，5 次"
        case .fist: "食指與中指伸直 → 握拳 → 伸直，10 次"
        case .hover: "伸出食指，讓白圈對準十字、盡量不動；十字會換 3 個位置"
        case .precise: "讓白圈在兩個十字之間慢慢來回，每次停在十字上"
        case .sweep: "大範圍快速移動食指，偶爾停下"
        case .tap: "食指伸直，只彎指尖兩節往下按再伸直（像按按鈕），指根與手掌不動，10 次"
        case .tapHold: "同上，按下後停約 1 秒再伸直，5 次"
        case .moveAndTap: "每到一個十字就按鍵一下！十字每 3 秒換位置：把白圈移過去，彎指尖兩節點一下"
        case .moveAndTrigger: "每到一個十字就扳機一下！十字每 3 秒換位置：把白圈移過去，拇指往下壓一下（右鍵）"
        case .threeFingerBend: "食指、中指、無名指伸直，小指收起，像平常捲動一樣彎一半再伸直，10 下"
        }
    }
}

/// 錄影腳本：依序進行的階段。
public struct Script: Sendable {
    public let name: String
    public let phases: [Phase]

    /// M0 可行性驗證。
    public static let m0 = Script(name: "m0", phases: [.warmup, .latency, .still, .move, .pinch, .wake, .daily])
    /// 候選手勢。`move` 階段供重播時校準。
    public static let gestures = Script(
        name: "gestures", phases: [.warmup, .move, .trigger, .triggerHold, .twoFingerTrigger, .halfBend, .reverseBend, .fist, .daily]
    )
    /// 防抖與按鍵式點擊。
    public static let precision = Script(
        name: "precision",
        phases: [.warmup, .move, .hover, .precise, .sweep, .tap, .tapHold, .twoFingerTrigger, .halfBend, .fist, .daily]
    )
    /// 實際使用的節奏：移過去就點，以及三指捲動。
    public static let controls = Script(
        name: "controls",
        phases: [.warmup, .move, .moveAndTap, .moveAndTrigger, .twoFingerTrigger, .halfBend, .threeFingerBend, .fist, .daily]
    )
    public static let all = [m0, gestures, precision, controls]

    public var totalDuration: Double {
        phases.reduce(0) { $0 + $1.duration }
    }

    /// 依開始後經過的秒數回傳當前階段與剩餘秒數；流程結束回傳 nil。
    public func at(elapsed: Double) -> (phase: Phase, remaining: Double)? {
        var end = 0.0
        for phase in phases {
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
    /// 影格擷取 → 送達 App（ms）。較早的紀錄沒有這個欄位。
    public var deliveryMs: Double?
    /// Vision 推論耗時（ms）。
    public var inferenceMs: Double
    public var hands: [Hand]
    /// 延遲比較階段的處理方式代號；其他階段為 nil。
    public var config: String?

    public init(
        t: Double, phase: Phase, width: Int, height: Int, latencyMs: Double, inferenceMs: Double, hands: [Hand],
        config: String? = nil, deliveryMs: Double? = nil
    ) {
        self.t = t
        self.phase = phase
        self.width = width
        self.height = height
        self.latencyMs = latencyMs
        self.inferenceMs = inferenceMs
        self.hands = hands
        self.config = config
        self.deliveryMs = deliveryMs
    }

    /// 主要操作手：優先右手，其次平均信心值最高者。
    public var primaryHand: Hand? {
        hands.primary
    }
}
