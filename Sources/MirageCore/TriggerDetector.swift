/// 手槍扳機：食指伸直、拇指豎起，拇指往下壓到食指側面是按下，抬起是放開。訊號是拇指尖到食指第二關節（PIP）
/// 的距離（掌寬）。手的位置與鏡頭角度不同時，壓下落在 0.20–0.37、抬起落在 0.38–0.77，固定門檻分不開，所以看
/// 變化：比最近 `window` 秒內的最高點低 `drop` 以上、連續 `frames` 幀，而且這段期間食指一直伸直，才算按下；比按下
/// 後的最低點高 `lift` 以上就放開。拇指一直貼著食指、沒有先抬起（例如兩指捲動時），不會觸發。握拳時拇指比食指早
/// 一兩幀收起，所以要連續三幀：食指在第三幀前就彎下了。
public struct TriggerDetector: Sendable {
    public var window = 0.5
    /// 掌寬。移過去就扳機時拇指常沒先抬高，只壓下 0.13–0.14；0.12 會在移動途中誤觸。
    public var drop = 0.13
    public var lift = 0.1
    /// 按下時距離須在此值以下：拇指要真的壓到食指旁。
    public var near = 0.4
    /// 食指尖比指根高出至少此掌寬才算伸直。
    public var straight = 0.6
    /// 這段期間食指高度的變化須在此掌寬以內：彎手指時食指 PIP 也會移動，拇指距離跟著變，但那不是扳機。
    public var steady = 0.25
    public var frames = 3

    public private(set) var isPressed = false
    /// 食指伸直期間、最近 `window` 秒內的距離與食指高度。
    private var history: [(t: Double, distance: Double, rise: Double?)] = []
    /// 按下後的最低距離。
    public private(set) var low = 0.0
    /// 連續比最高點低 `drop` 的幀數。
    private var downFrames = 0

    public init() {}

    /// `distance`：拇指尖到食指 PIP ÷ 掌寬，量不到時為 nil（維持原狀態）；`rise`：食指尖比指根高出幾個掌寬，
    /// 量不到時為 nil（不擋）；`posed`：無名指與小指收起（指向或兩指伸直）。回傳 true 表示此幀確認按下。
    /// 食指彎下或姿勢不對時放開：握拳時拇指也貼著食指，不能一直按著。
    public mutating func update(distance: Double?, rise: Double?, posed: Bool, at t: Double) -> Bool {
        guard let distance else { return false }
        guard posed, (rise ?? straight) >= straight else {
            history = []
            downFrames = 0
            isPressed = false
            return false
        }
        if isPressed {
            low = min(low, distance)
            if distance - low >= lift { isPressed = false }
            return false
        }
        history.append((t, distance, rise))
        history.removeAll { t - $0.t > window }
        let rises = history.compactMap(\.rise)
        let calm = (rises.max() ?? 0) - (rises.min() ?? 0) <= steady
        let down = calm && distance <= near && (history.map(\.distance).max() ?? distance) - distance >= drop
        downFrames = down ? downFrames + 1 : 0
        guard downFrames >= frames else { return false }
        isPressed = true
        low = distance
        history = []
        downFrames = 0
        return true
    }
}
