/// 使用者的操作範圍與手的大小，由校準取得。範圍是正規化影像座標（0...1，原點左下，未鏡像）。
public struct Calibration: Codable, Sendable, Equatable {
    /// 操作時的掌寬（像素），手勢閘門以此為基準。
    public var palmWidth: Double
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(palmWidth: Double, minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.palmWidth = palmWidth
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }
}

/// 校準流程：使用者伸出食指，在舒適範圍內畫大圈。看得到食指指向的時間先倒數 `countdown` 秒，讓使用者看完說明、
/// 準備好；再累計 `duration` 秒後，取掌寬中位數與食指尖位置的 5–95% 範圍：去掉偶發的極端值，也讓游標不必把手
/// 伸到最遠就能到達螢幕邊緣。只收指向的幀：掌寬要在實際操作的姿勢與距離量（M0.2 靜止時手較靠近鏡頭，掌寬比移動
/// 時大 13%），也順便確認這個姿勢認得出來。
public struct CalibrationSession: Sendable {
    /// 這一幀為什麼有或沒有累計時間，讓使用者知道要怎麼調整。
    public enum Hint: Sendable, Equatable {
        case noHand
        /// 看得到手，但不是食指指向。
        case notPointing
        case pointing
    }

    public enum Progress: Sendable, Equatable {
        /// 看到食指指向，倒數結束才開始收集。
        case countdown(remaining: Double)
        case collecting(remaining: Double, hint: Hint)
        case done(Calibration)
        /// 移動範圍太小，已重新開始收集。
        case tooSmall
    }

    /// 開始收集前，食指指向要累計的秒數。
    public var countdown = 3.0
    public var duration = 4.0
    /// 範圍寬高的下限（正規化座標）。範圍太小時游標會過度敏感。
    public var minSpan = 0.1
    /// 相鄰兩幀相隔超過此秒數不累計時間（手離開畫面後再入鏡）。
    public var maxStep = 0.1
    /// 累計的指向時間，含倒數。
    private var elapsed = 0.0
    private var lastT: Double?
    private var palms: [Double] = []
    private var tips: [Vec2] = []

    public init() {}

    public mutating func update(hands: [Hand], width: Int, height: Int, at t: Double) -> Progress {
        let remaining = min(duration, countdown + duration - elapsed)
        guard let hand = hands.primary else {
            lastT = nil
            return .collecting(remaining: remaining, hint: .noHand)
        }
        let geometry = HandGeometry(hand: hand, width: width, height: height)
        guard let palm = geometry.palmWidth, let tip = geometry.normalized(.indexTip),
              geometry.isPointing(palmWidth: palm) == true
        else {
            lastT = nil
            return .collecting(remaining: remaining, hint: .notPointing)
        }
        if let lastT, t - lastT <= maxStep { elapsed += t - lastT }
        lastT = t
        guard elapsed >= countdown else { return .countdown(remaining: countdown - elapsed) }
        palms.append(palm)
        tips.append(tip)
        guard elapsed >= countdown + duration else {
            return .collecting(remaining: countdown + duration - elapsed, hint: .pointing)
        }

        let xs = tips.map(\.x)
        let ys = tips.map(\.y)
        guard let palmWidth = SpikeAnalysis.percentile(palms, 0.5),
              let minX = SpikeAnalysis.percentile(xs, 0.05), let maxX = SpikeAnalysis.percentile(xs, 0.95),
              let minY = SpikeAnalysis.percentile(ys, 0.05), let maxY = SpikeAnalysis.percentile(ys, 0.95),
              maxX - minX >= minSpan, maxY - minY >= minSpan
        else {
            elapsed = 0
            lastT = nil
            palms = []
            tips = []
            return .tooSmall
        }
        return .done(Calibration(palmWidth: palmWidth, minX: minX, minY: minY, maxX: maxX, maxY: maxY))
    }
}
