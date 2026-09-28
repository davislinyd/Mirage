/// 按鍵式點擊：食指伸直時只彎指尖兩節往下按（像按按鈕），指根與手掌不動。訊號是食指 PIP 與 DIP 兩個關節在畫面上
/// 的彎曲角度相加（度）。錄影（手放低、1:1 畫面）中，按下時 0.3 秒內上升 20–80°，懸停與慢速對準時最多 10°；
/// 快速移動與日常動作偶爾也有 30° 以上的假彎曲。所以要最近 `window` 秒內上升 `rise` 以上、連續 `frames` 幀，並且：
/// - 手掌（四個指根的中心）速度低於 `stillSpeed` 掌寬／秒。移到目標後馬上按時手還沒完全停，按的動作本身也會讓
///   指根晃動，真的按鍵最高到 0.58，所以不能要求完全靜止。
/// - 開始彎的那一幀（彎曲量最小）手掌速度低於 `settledSpeed`：快速移動剛停下時的假彎曲，開始彎時手掌還在 1.25
///   以上；真的按鍵最高 0.73。
/// - 食指尖仍比指根高出 `minHeight` 掌寬以上：只彎指尖兩節時最低約 0.42；快速移動時整根食指從指根往下甩，會低到
///   0.15–0.28。
/// - 從開始彎的那一幀起，中指尖抬高不超過 `middleRise` 掌寬：按鍵時最多 0.06；從指向換成兩指、張手再握拳時食指
///   也會先彎，但中指同時抬高 0.12 以上。
/// 彎曲量回到上升量的一半以下就放開。
public struct TapDetector: Sendable {
    public var window = 0.3
    /// 度。
    public var rise = 20.0
    public var frames = 2
    public var stillSpeed = 0.5
    public var settledSpeed = 1.0
    /// 掌寬。
    public var minHeight = 0.35
    /// 掌寬。
    public var middleRise = 0.1

    public private(set) var isPressed = false
    /// 按下前的彎曲量（度）。
    public private(set) var base = 0.0
    /// 最近 `window` 秒內、姿勢正確的幀的彎曲量、手掌速度與中指高度。按下時食指一彎，偶爾有一兩幀看起來不是指向
    /// 姿勢：跳過這些幀，不清掉紀錄，否則基準會變成已經彎下去的那一幀。
    private var history: [(t: Double, flex: Double, palmSpeed: Double?, middle: Double?)] = []
    /// 連續符合按下條件的幀數。
    private var downFrames = 0

    public init() {}

    /// `flex`：食指 PIP＋DIP 彎曲角度（度），量不到時為 nil（維持原狀態）；`height`、`middle`：食指尖、中指尖比
    /// 各自的指根高出幾個掌寬，量不到時為 nil（不擋）；`posed`：中指、無名指、小指收起，食指尖仍高於指根（按下時
    /// 食指會彎，不能要求完全伸直）；`palmSpeed`：手掌速度（掌寬／秒），量不到時為 nil。回傳 true 表示此幀確認
    /// 按下。姿勢不對時放開。
    public mutating func update(
        flex: Double?, height: Double?, middle: Double?, posed: Bool, palmSpeed: Double?, at t: Double
    ) -> Bool {
        guard let flex else { return false }
        history.removeAll { t - $0.t > window }
        let low = history.map(\.flex).min() ?? flex
        // 最小值有好幾幀時取最後一幀：開始彎之前的最後一刻。
        let rest = history.last { $0.flex == low }
        if posed { history.append((t, flex, palmSpeed, middle)) }
        if isPressed {
            if !posed || flex - base <= rise / 2 { isPressed = false }
            return false
        }
        let settled = (rest?.palmSpeed ?? .infinity) < settledSpeed
        let curled = (middle.flatMap { m in rest?.middle.map { m - $0 } } ?? 0) <= middleRise
        let down = posed && flex - low >= rise && (palmSpeed ?? .infinity) < stillSpeed && settled
            && (height ?? minHeight) >= minHeight && curled
        downFrames = down ? downFrames + 1 : 0
        guard downFrames >= frames else { return false }
        isPressed = true
        base = low
        downFrames = 0
        return true
    }
}
