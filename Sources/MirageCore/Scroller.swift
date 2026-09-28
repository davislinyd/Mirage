/// 兩指或三指捲動：食指與中指（三指再加無名指）一起伸直 `hold` 秒後進入捲動（游標停住），之後彎、伸手指來捲；只有
/// 食指伸直持續 `release` 秒才離開。捲動訊號是食指尖比食指根高出幾個掌寬（`height`），整隻手移動時不變。
///
/// 高度從這一下到過的最遠處往回超過 `reversal` 掌寬，就算換成下一下。手放低時鏡頭從上方斜看，彎一半在畫面上只降
/// 約 0.5 掌寬，所以不用固定的彎曲門檻。扳機（拇指壓食指）時食指只晃約 0.15，不會算成一下。
///
/// 彎下的那一下捲動，距離是指尖高度的變化 × `scale`；伸直回來不捲。錄影中彎、伸的速度沒有一致的差別，無法從動作
/// 本身分辨哪一下是滑過去、哪一下是收回來，所以方向由伸直的手指數決定（`direction`）：兩指時內容往下（看到上面），
/// 三指時內容往上（看到下面）。捲動中換成另一種手指數並維持 `hold` 秒就換方向。
///
/// 每一下停住（這一幀沒有更遠）時，依最後 `flickWindow` 秒的速度繼續捲動並逐漸減速（慣性），速度未達
/// `flickSpeed` 則不捲；時間常數 `decay` 秒，約同 iOS 捲動的一般減速。下一下開始捲動時取代慣性，離開捲動後
/// 慣性照常跑完。
public struct Scroller: Sendable {
    /// 彎手指時內容移動的方向。
    public enum Direction: Sendable, Equatable {
        /// 兩指：內容往下，看到上面的內容。
        case down
        /// 三指：內容往上，看到下面的內容。
        case up
    }

    public var hold = 0.1
    /// 只有食指伸直持續此秒數才結束捲動：彎、伸的途中，手指不一定同時動，常有 1–2 幀看起來像只有食指伸直。
    public var release = 0.2
    /// 掌寬。
    public var reversal = 0.25
    /// pt／掌寬。
    public var scale = 200.0
    public var flickWindow = 0.1
    /// pt/s。
    public var flickSpeed = 300.0
    public var stopSpeed = 20.0
    public var decay = 0.5

    /// 捲動中（不含離開後的慣性）：游標停住，不點擊。
    public private(set) var isScrolling = false
    public private(set) var direction = Direction.down

    /// 目前伸直的手指對應的方向，與開始的時間。
    private var pose: (direction: Direction, since: Double)?
    private var pointingSince: Double?
    /// 這一下的方向：往上（伸直）為 1，往下（彎曲）為 −1。
    private var heading = 1.0
    /// 這一下到過最遠的高度。
    private var extreme: Double?
    /// 彎下的這一下還在前進。
    private var moving = false
    /// 最近 2 × `flickWindow` 秒內量到的高度。
    private var recent: [(height: Double, t: Double)] = []
    /// 慣性速度（pt/s）與上次捲動的時間。
    private var momentum: (velocity: Double, t: Double)?
    /// 還沒送出、不足 1 pt 的捲動距離。
    private var remainder = 0.0

    public init() {}

    /// `twoFingers`：食指與中指伸直；`threeFingers`：食指、中指、無名指伸直；`pointing`：只有食指伸直；`height`：
    /// 食指尖比食指根高出幾個掌寬，量不到時為 nil。回傳這一幀要捲動的整數 pt，內容往上為正。
    public mutating func update(twoFingers: Bool, threeFingers: Bool, pointing: Bool, height: Double?, at t: Double) -> Double? {
        let seen: Direction? = threeFingers ? .up : twoFingers ? .down : nil
        if let seen {
            if pose?.direction != seen { pose = (seen, t) }
        } else {
            pose = nil
        }
        pointingSince = pointing ? (pointingSince ?? t) : nil
        if let pose, t - pose.since >= hold {
            if !isScrolling {
                isScrolling = true
                heading = 1
                extreme = nil
                moving = false
                recent = []
                momentum = nil
            }
            direction = pose.direction
        }
        if isScrolling, let pointingSince, t - pointingSince >= release { isScrolling = false }
        var delta = 0.0
        if isScrolling, let height { delta = track(height, at: t) }
        if let momentum, t > momentum.t {
            let v = momentum.velocity / (1 + (t - momentum.t) / decay)
            delta += v * (t - momentum.t)
            self.momentum = abs(v) >= stopSpeed ? (velocity: v, t: t) : nil
        }
        remainder += delta
        let whole = remainder.rounded(.towardZero)
        remainder -= whole
        return whole == 0 ? nil : whole
    }

    /// 內容往上為正：兩指時內容跟著指尖往下，三指時相反。
    private var sign: Double { direction == .down ? 1 : -1 }

    /// 回傳這一下捲動的距離（pt）。
    private mutating func track(_ height: Double, at t: Double) -> Double {
        var delta = 0.0
        var advanced = false
        if let extreme {
            let reversed = (extreme - height) * heading >= reversal
            if reversed { heading = -heading }
            if reversed || (height - extreme) * heading > 0 {
                if heading < 0 {
                    delta = (height - extreme) * scale * sign
                    advanced = true
                }
                self.extreme = height
            }
        } else {
            extreme = height
        }
        if advanced {
            moving = true
            momentum = nil
        } else if moving {
            moving = false
            flick()
        }
        recent.removeAll { $0.t < t - 2 * flickWindow }
        recent.append((height, t))
        return delta
    }

    /// 這一下停住：依最後 `flickWindow` 秒（到上一幀為止）的速度開始慣性。
    private mutating func flick() {
        guard let last = recent.last, let start = recent.last(where: { $0.t <= last.t - flickWindow }) ?? recent.first,
              last.t > start.t else { return }
        let bend = (start.height - last.height) / (last.t - start.t) * scale
        if bend >= flickSpeed { momentum = (-bend * sign, last.t) }
    }
}
