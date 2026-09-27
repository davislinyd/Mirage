/// 兩指捲動：食指與中指一起伸直 `hold` 秒後開始，手上下移動的距離 × `gain` 就是捲動距離，內容跟著手動（同觸控板
/// 的自然捲動）。看到只有食指伸直才停止；停止時捲動速度達 `flickSpeed`，就依當下速度繼續捲動並逐漸減速（慣性），
/// 時間常數 `decay` 秒，約同 iOS 捲動的一般減速。手的高度用食指根部而不是指尖：手指彎曲、收回中指時指尖會移動，
/// 根部幾乎不動。
public struct Scroller: Sendable {
    public var hold = 0.1
    public var gain = 2.0
    /// pt/s。
    public var flickSpeed = 300.0
    public var stopSpeed = 20.0
    public var decay = 0.5

    /// 捲動或慣性捲動中：游標停住，不點擊。
    public var isEngaged: Bool { engaged || momentum != nil }

    private var twoFingersSince: Double?
    private var engaged = false
    private var filter = OneEuroFilter()
    private var last: (y: Double, t: Double)?
    /// 捲動速度（pt/s）。
    private var velocity = 0.0
    private var momentum: (velocity: Double, t: Double)?
    /// 還沒送出、不足 1 pt 的捲動距離。
    private var remainder = 0.0

    public init() {}

    /// `twoFingers`：食指與中指伸直；`pointing`：只有食指伸直；`y`：食指根部的高度（螢幕 pt，往上為正），看不到時為 nil。
    /// 回傳這一幀要捲動的整數 pt，內容往上為正。
    public mutating func update(twoFingers: Bool, pointing: Bool, y: Double?, at t: Double) -> Double? {
        twoFingersSince = twoFingers ? (twoFingersSince ?? t) : nil
        if !engaged, let twoFingersSince, t - twoFingersSince >= hold {
            engaged = true
            momentum = nil
        }
        var delta = 0.0
        if engaged, pointing {
            engaged = false
            if abs(velocity) >= flickSpeed { momentum = (velocity: velocity, t: t) }
            last = nil
            velocity = 0
        } else if engaged, let y {
            // 每次重新看到手，從目前位置開始算，不追舊位置。
            if last == nil { filter.reset() }
            let filtered = filter(y, at: t)
            if let last, t > last.t {
                delta = (filtered - last.y) * gain
                velocity += 0.5 * (delta / (t - last.t) - velocity)
            }
            last = (filtered, t)
        } else if engaged {
            last = nil
        } else if let momentum, t > momentum.t {
            let v = momentum.velocity / (1 + (t - momentum.t) / decay)
            delta = v * (t - momentum.t)
            self.momentum = abs(v) >= stopSpeed ? (velocity: v, t: t) : nil
        }
        remainder += delta
        let whole = remainder.rounded(.towardZero)
        remainder -= whole
        return whole == 0 ? nil : whole
    }
}
