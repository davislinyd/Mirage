/// 兩指甩動捲動：食指與中指一起伸直 `hold` 秒後進入捲動（游標停住）。之後食指尖往上或往下快速一甩（兩幀間的
/// 速度達 `upSpeed`／`downSpeed`），內容就跟著指尖移動（指尖移動 × `scale`），甩完再依最後 `flickWindow` 秒的
/// 速度繼續捲動並逐漸減速（慣性，時間常數 `decay` 秒）；慢慢收回來不捲。只有食指伸直持續 `release` 秒才離開。
///
/// 刻意的一甩與收回來的回程靠速度分辨。swipe 錄影中：
/// - 往下甩是彎手指，峰值 12.9–20 掌寬/秒；往上甩是抬手，多在 7.9–12.7。
/// - 往上甩之後手放下來的回程多在 4.7 以下，但太慢、沒算成一甩的那一下，回程可到約 6.2：往下的門檻所以比較高。
/// - 往下甩之後手指伸直回來可達 7.6，但都在甩動開始後 0.73 秒內。
/// - 連續往上甩時，下一下之前常先很快彎一下手指（預備動作，約 12.5），在上一下開始後約 1.06 秒。
/// 所以甩動開始後 `refractory` 秒內不接受反方向的甩動；要換方向，先停一下。
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
    public var refractory = 1.5
    /// pt／掌寬。
    public var scale = 200.0
    public var flickWindow = 0.1
    /// pt/s：甩完時速度達此值才慣性捲動。
    public var glideSpeed = 300.0
    public var stopSpeed = 20.0
    public var decay = 0.5

    /// 捲動中（不含離開後的慣性）：游標停住，不點擊。
    public private(set) var isScrolling = false
    public private(set) var direction = Direction.still

    private var twoFingersSince: Double?
    private var pointingSince: Double?
    /// 最近三幀的指尖高度：速度取頭尾兩幀，比單幀穩。
    private var history: [(level: Double, t: Double)] = []
    /// 目前移動的方向：往上為 1，往下為 −1。
    private var heading = 0.0
    /// 這個方向開始移動前的高度。
    private var anchor = 0.0
    /// 甩動中：已捲到、到過最遠的高度。
    private var flicking: Double?
    /// 上一次甩動的方向與開始時間。
    private var lastFlick: (heading: Double, t: Double)?
    /// 最近 2 × `flickWindow` 秒內量到的高度。
    private var recent: [(level: Double, t: Double)] = []
    /// 慣性速度（pt/s）與上次捲動的時間。
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
            flicking = nil
            lastFlick = nil
            recent = []
            momentum = nil
        }
        if isScrolling, let pointingSince, t - pointingSince >= release { isScrolling = false }
        var delta = 0.0
        if isScrolling, let level { delta = track(level, at: t) }
        if let momentum, t > momentum.t {
            let v = momentum.velocity / (1 + (t - momentum.t) / decay)
            delta += v * (t - momentum.t)
            self.momentum = abs(v) >= stopSpeed ? (velocity: v, t: t) : nil
        }
        let moving = flicking != nil ? heading : momentum?.velocity ?? 0
        direction = moving > 0 ? .up : moving < 0 ? .down : .still
        remainder += delta
        let whole = remainder.rounded(.towardZero)
        remainder -= whole
        return whole == 0 ? nil : whole
    }

    /// 回傳這一幀甩動捲動的距離（pt）。
    private mutating func track(_ level: Double, at t: Double) -> Double {
        defer {
            recent.removeAll { $0.t < t - 2 * flickWindow }
            recent.append((level, t))
        }
        history.append((level, t))
        if history.count > 3 { history.removeFirst() }
        guard history.count == 3, t > history[0].t else { return 0 }
        let velocity = (level - history[0].level) / (t - history[0].t)
        if let flicking {
            if velocity * heading > 0 {
                // 只捲到過最遠的地方：甩到底時指尖常先往回彈一點。
                guard (level - flicking) * heading > 0 else { return 0 }
                self.flicking = level
                return (level - flicking) * scale
            }
            self.flicking = nil
            glide()
            return 0
        }
        let moving = velocity > 0 ? 1.0 : velocity < 0 ? -1.0 : 0
        if moving != 0, moving != heading {
            heading = moving
            anchor = history[1].level
        }
        guard heading != 0, velocity * heading >= (heading > 0 ? upSpeed : downSpeed) else { return 0 }
        if let lastFlick, lastFlick.heading != heading, t - lastFlick.t < refractory { return 0 }
        lastFlick = (heading, t)
        flicking = level
        momentum = nil
        return (level - anchor) * scale
    }

    /// 甩完：依最後 `flickWindow` 秒（到上一幀為止）的速度開始慣性。
    private mutating func glide() {
        guard let last = recent.last, let start = recent.last(where: { $0.t <= last.t - flickWindow }) ?? recent.first,
              last.t > start.t else { return }
        let velocity = (last.level - start.level) / (last.t - start.t) * scale
        if velocity * heading >= glideSpeed { momentum = (velocity, last.t) }
    }
}
