/// 五指捏合（張手 → 五指尖捏成一點）偵測：張手維持 `hold` 秒後，`maxGap` 秒內五指尖收攏（`tipSpread` ≤ `near`）、
/// 四指尖平均不低於指根 `low` 以下（`tipRise`），而且拇指尖碰到中指尖（≤ `touch`），連續 `frames` 幀才觸發。觸發後要
/// 重新張手。
///
/// 握拳時五個指尖在畫面上也收得很攏（`tipSpread` 低到 0.37），要靠另外兩項分開。三份 `gather` 錄影中，每一下取最像
/// 捏合的連續 3 幀：
/// - 照平常速度捏合時，指尖降到和指根差不多高（`tipRise` −0.16–0.32），`pose` 常判成握拳，所以不能看到握拳就重置；
///   握拳是 −0.41 到 −0.17。
/// - 拇指尖到中指尖：捏合 0.09–0.30，握拳時拇指壓在食指上，0.31–0.55。
/// 兩項都有握拳靠近門檻，但沒有一個握拳兩項同時通過。
public struct GatherDetector: Sendable {
    public var hold = 0.2
    public var maxGap = 0.6
    /// 掌寬。捏合時每一下最收攏的 3 幀 ≤ 0.43。
    public var near = 0.5
    /// 掌寬。
    public var low = -0.25
    /// 掌寬。
    public var touch = 0.35
    public var frames = 3

    /// 這段張手的開始與最後一幀的時間。
    private var open: (since: Double, last: Double)?
    /// 連續收攏的幀數。
    private var count = 0

    public init() {}

    /// `pose`：手勢，看不到手時為 nil；`spread`、`rise`：`HandGeometry.tipSpread`、`tipRise`；`thumb`：拇指尖到中指尖
    /// ÷ 掌寬。量不到時為 nil。回傳 true 表示此幀觸發。
    public mutating func update(pose: HandPose?, spread: Double?, rise: Double?, thumb: Double?, at t: Double) -> Bool {
        let gathered = (spread.map { $0 <= near } ?? false) && (rise.map { $0 >= low } ?? false) && (thumb.map { $0 <= touch } ?? false)
        // 捏合剛開始時手指還沒彎，`pose` 仍是張手，所以先看收攏。
        if !gathered, pose == .open {
            open = open.flatMap { t - $0.last <= maxGap ? ($0.since, t) : nil } ?? (t, t)
            count = 0
            return false
        }
        guard gathered, let open, open.last - open.since >= hold, t - open.last <= maxGap else {
            count = 0
            return false
        }
        count += 1
        guard count >= frames else { return false }
        self.open = nil
        count = 0
        return true
    }
}
