/// 兩指甩動捲動：食指與中指一起伸直 `hold` 秒後進入捲動（游標停住）。之後食指尖往上或往下快速一甩（兩幀間的
/// 速度達 `upSpeed`／`downSpeed`），內容就往那個方向捲，像在觸控板上甩一下：捲動速度 = `flingSpeed` × 這一甩最快
/// 的速度 ÷ 門檻（最多 `maxSpeed`），甩完逐漸減速（時間常數 `decay` 秒）；慢慢收回來不捲。只有食指伸直持續 `release`
/// 秒才離開。
///
/// 捲動速度看這一甩最快的時候，而不是甩完前的最後一刻：甩到底常停一下才收回，那時速度幾乎是 0，實機試用時約一半的
/// 甩動因此沒有慣性，只捲 150–420 pt 就停。除以各自的門檻，是因為往下甩（彎手指）本來就比往上甩（抬手）快，同樣用力
/// 時滑的距離才差不多。
///
/// 刻意的一甩與收回來的回程靠速度分辨。swipe 錄影中：
/// - 往下甩是彎手指，峰值 12.9–20 掌寬/秒；往上甩是抬手，多在 7.9–12.7。
/// - 往上甩之後手放下來的回程多在 4.7 以下，但太慢、沒算成一甩的那一下，回程可到約 6.2：往下的門檻所以比較高。
/// - 往下甩之後手指伸直回來可達 8.8（兩幀速度），在甩動開始後 0.9 秒內。
/// - 連續往上甩時，下一下之前常先很快彎一下手指（預備動作，10.3），在上一下開始後約 1.07 秒。
/// 所以甩動開始後 `refractory` 秒內不接受反方向的甩動；要換方向，先停一下。取 1.2 秒，比 0.9、1.07 秒晚一點，換方向
/// 不用等太久（原本 1.5 秒，試用時覺得太久）。回程不一定慢：實機試用時，往下甩之後
/// 手指伸直回來 14 次中有 11 次超過每秒 12 掌寬，和刻意往上甩（中位數 15）分不開，不能用「甩得更用力」提早換方向。
/// 舊錄影「彎一半再伸直」的節奏去回一樣快，分不開：要甩，並慢慢收回。
public struct Scroller: Sendable {
    /// 目前內容移動的方向。
    public enum Direction: Sendable, Equatable {
        /// 沒有在捲。
        case still
        /// 指尖往上甩，內容往上，看到下面的內容。
        case up
        /// 指尖往下甩，內容往下，看到上面的內容。
        case down
    }

    public var hold = 0.1
    /// 只有食指伸直持續此秒數才結束捲動：彎、伸的途中，手指不一定同時動，常有 1–2 幀看起來像只有食指伸直。
    public var release = 0.2
    /// 掌寬/秒。
    public var upSpeed = 6.0
    /// 掌寬/秒。
    public var downSpeed = 8.0
    /// 秒。
    public var refractory = 1.2
    /// pt/s：剛好達門檻的一甩。
    public var flingSpeed = 1200.0
    /// pt/s。
    public var maxSpeed = 4000.0
    public var stopSpeed = 20.0
    public var decay = 0.5

    /// 捲動中（不含離開後的慣性）：游標停住，不點擊。
    public private(set) var isScrolling = false
    public private(set) var direction = Direction.still

    private var twoFingersSince: Double?
    private var pointingSince: Double?
    /// 最近三幀的指尖高度：速度取頭尾兩幀，比單幀穩。
    private var history: [(level: Double, t: Double)] = []
    /// 目前移動或甩動的方向：往上為 1，往下為 −1。
    private var heading = 0.0
    private var flicking = false
    /// 上一次甩動的方向與開始時間。
    private var lastFlick: (heading: Double, t: Double)?
    /// 捲動速度（pt/s，內容往上為正）與上次捲動的時間。
    private var momentum: (velocity: Double, t: Double)?
    /// 還沒送出、不足 1 pt 的捲動距離。
    private var remainder = 0.0

    public init() {}

    /// `twoFingers`：食指與中指伸直；`pointing`：只有食指伸直；`level`：食指尖的高度（掌寬，往上為正），量不到時為
    /// nil。回傳這一幀要捲動的整數 pt，內容往上為正。
    public mutating func update(twoFingers: Bool, pointing: Bool, level: Double?, at t: Double) -> Double? {
        twoFingersSince = twoFingers ? (twoFingersSince ?? t) : nil
        pointingSince = pointing ? (pointingSince ?? t) : nil
        if !isScrolling, let twoFingersSince, t - twoFingersSince >= hold {
            isScrolling = true
            history = []
            heading = 0
            flicking = false
            lastFlick = nil
            momentum = nil
        }
        if isScrolling, let pointingSince, t - pointingSince >= release { isScrolling = false }
        if isScrolling, let level { track(level, at: t) }
        var delta = 0.0
        if let momentum, t > momentum.t {
            let v = momentum.velocity / (1 + (t - momentum.t) / decay)
            delta = v * (t - momentum.t)
            self.momentum = abs(v) >= stopSpeed ? (velocity: v, t: t) : nil
        }
        let moving = momentum?.velocity ?? 0
        direction = moving > 0 ? .up : moving < 0 ? .down : .still
        remainder += delta
        let whole = remainder.rounded(.towardZero)
        remainder -= whole
        return whole == 0 ? nil : whole
    }

    /// 甩動開始時設定捲動速度，甩動中跟到這一甩最快的速度。
    private mutating func track(_ level: Double, at t: Double) {
        history.append((level, t))
        if history.count > 3 { history.removeFirst() }
        guard history.count == 3, t > history[0].t else { return }
        let velocity = (level - history[0].level) / (t - history[0].t)
        if flicking {
            guard velocity * heading > 0 else {
                flicking = false
                return
            }
            if let momentum, fling(velocity) > abs(momentum.velocity) { self.momentum = (fling(velocity) * heading, momentum.t) }
            return
        }
        guard velocity != 0 else { return }
        heading = velocity > 0 ? 1 : -1
        guard abs(velocity) >= (heading > 0 ? upSpeed : downSpeed) else { return }
        if let lastFlick, lastFlick.heading != heading, t - lastFlick.t < refractory { return }
        lastFlick = (heading, t)
        flicking = true
        // 同方向還在滑時取比較快的；從上一幀算起，這一幀就開始捲。
        let gliding = momentum.map { $0.velocity * heading } ?? 0
        momentum = (max(gliding, fling(velocity)) * heading, history[1].t)
    }

    /// 指尖速度（掌寬/秒）→ 捲動速度（pt/s，不分方向）。
    private func fling(_ velocity: Double) -> Double {
        min(abs(velocity) / (velocity > 0 ? upSpeed : downSpeed) * flingSpeed, maxSpeed)
    }
}
