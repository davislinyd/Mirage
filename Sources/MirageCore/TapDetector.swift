/// 按鍵式點擊：食指伸直時只彎指尖兩節往下按（像按按鈕），指根與手掌不動。訊號是食指 PIP 與 DIP 兩個關節在畫面上
/// 的彎曲角度相加（度）。兩份錄影（手放低、1:1 畫面）中，按下時 0.3 秒內上升 20–80°，懸停與慢速對準時最多 10°；
/// 快速移動與日常動作偶爾也有 30° 的假彎曲，但那時手掌在動。所以要最近 `window` 秒內上升 `rise` 以上、連續
/// `frames` 幀，而且手掌（四個指根的中心）速度低於 `stillSpeed` 掌寬／秒；彎曲量回到上升量的一半以下就放開。
/// 這樣兩份錄影的 46 下按鍵抓到 45 下、按住 10/10，其他階段 0 次。
public struct TapDetector: Sendable {
    public var window = 0.3
    /// 度。
    public var rise = 20.0
    public var frames = 2
    public var stillSpeed = 0.3

    public private(set) var isPressed = false
    /// 按下前的彎曲量（度）。
    public private(set) var base = 0.0
    /// 最近 `window` 秒內、姿勢正確的幀的彎曲量。按下時食指一彎，偶爾有一兩幀看起來不是指向姿勢：跳過這些幀，
    /// 不清掉紀錄，否則基準會變成已經彎下去的那一幀。
    private var history: [(t: Double, flex: Double)] = []
    /// 連續符合按下條件的幀數。
    private var downFrames = 0

    public init() {}

    /// `flex`：食指 PIP＋DIP 彎曲角度（度），量不到時為 nil（維持原狀態）；`posed`：中指、無名指、小指收起，
    /// 食指尖仍高於指根（按下時食指會彎，不能要求完全伸直）；`palmSpeed`：手掌速度（掌寬／秒），量不到時為 nil。
    /// 回傳 true 表示此幀確認按下。姿勢不對時放開。
    public mutating func update(flex: Double?, posed: Bool, palmSpeed: Double?, at t: Double) -> Bool {
        guard let flex else { return false }
        history.removeAll { t - $0.t > window }
        let low = history.map(\.flex).min() ?? flex
        if posed { history.append((t, flex)) }
        if isPressed {
            if !posed || flex - base <= rise / 2 { isPressed = false }
            return false
        }
        let down = posed && flex - low >= rise && (palmSpeed ?? .infinity) < stillSpeed
        downFrames = down ? downFrames + 1 : 0
        guard downFrames >= frames else { return false }
        isPressed = true
        base = low
        downFrames = 0
        return true
    }
}
