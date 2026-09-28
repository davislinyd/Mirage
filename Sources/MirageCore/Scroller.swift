/// 兩指捲動：食指與中指一起伸直 `hold` 秒後進入捲動（游標停住），之後彎、伸兩指來捲；只有食指伸直持續 `release`
/// 秒才離開。捲動訊號是食指尖比食指根高出幾個掌寬（`height`），整隻手移動時不變。
///
/// 高度從這一下到過的最遠處往回超過 `reversal` 掌寬，就算換成下一下。手放低時鏡頭從上方斜看，彎一半在畫面上只降
/// 約 0.5 掌寬，所以不用固定的彎曲門檻。扳機（拇指壓食指）時食指只晃約 0.15，不會算成一下。
///
/// 手指停在同一端 `dwell` 秒，那一端就成為起點：離開起點的那一下捲動，距離是指尖高度的變化 × `scale`，內容跟著指尖
/// 移動；回到起點的那一下不捲。錄影中彎、伸的速度沒有一致的差別，無法從動作本身分辨哪一下是滑過去、哪一下是收回來，
/// 所以用停留的位置分辨。進入捲動時兩指伸直，每彎一下，內容往下移一段；彎著停 `dwell` 秒後改成每伸直一下，內容往上
/// 移一段；再伸直停 `dwell` 秒就換回來。錄影中一般捲動時兩下之間最久停約 0.7 秒；刻意停住換方向時只停了 0.3–0.8
/// 秒，所以停在另一端時提供進度（`switching`），讓使用者看到提示翻轉再動。
///
/// 每一下停住（這一幀沒有更遠）時，依最後 `flickWindow` 秒的速度繼續捲動並逐漸減速（慣性），速度未達
/// `flickSpeed` 則不捲；時間常數 `decay` 秒，約同 iOS 捲動的一般減速。下一下開始捲動時取代慣性，離開捲動後
/// 慣性照常跑完。
public struct Scroller: Sendable {
    /// 會捲動的那一下。
    public enum Stroke: Sendable, Equatable {
        /// 起點在伸直端：彎手指捲動，指尖往下。
        case bend
        /// 起點在彎曲端：伸直手指捲動，指尖往上。
        case straighten
    }

    public var hold = 0.1
    /// 只有食指伸直持續此秒數才結束捲動：彎、伸的途中，食指與中指不一定同時動，常有 1–2 幀看起來像只有食指伸直。
    public var release = 0.2
    /// 掌寬。
    public var reversal = 0.25
    public var dwell = 1.2
    /// 高度變化在此掌寬以內算停住。
    public var stillness = 0.1
    /// pt／掌寬。
    public var scale = 200.0
    public var flickWindow = 0.1
    /// pt/s。
    public var flickSpeed = 300.0
    public var stopSpeed = 20.0
    public var decay = 0.5

    /// 兩指捲動中（不含離開後的慣性）：游標停住，不點擊。
    public private(set) var isScrolling = false
    public private(set) var stroke = Stroke.bend
    /// 停在起點以外那一端時，換起點的進度（0...1）；沒有要換時為 nil。
    public private(set) var switching: Double?

    private var twoFingersSince: Double?
    private var pointingSince: Double?
    /// 這一下的方向：往上（停在伸直端）為 1，往下為 −1。
    private var heading = 1.0
    /// 這一下到過最遠的高度。
    private var extreme: Double?
    /// 開始停住時的高度與時間。
    private var rest: (height: Double, t: Double)?
    /// 捲動的這一下還在前進。
    private var moving = false
    /// 最近 2 × `flickWindow` 秒內量到的高度。
    private var recent: [(height: Double, t: Double)] = []
    /// 慣性速度（pt/s）與上次捲動的時間。
    private var momentum: (velocity: Double, t: Double)?
    /// 還沒送出、不足 1 pt 的捲動距離。
    private var remainder = 0.0

    public init() {}

    /// `twoFingers`：食指與中指伸直；`pointing`：只有食指伸直；`height`：食指尖比食指根高出幾個掌寬，量不到時為 nil。
    /// 回傳這一幀要捲動的整數 pt，指尖往上為正，內容跟著指尖移動。
    public mutating func update(twoFingers: Bool, pointing: Bool, height: Double?, at t: Double) -> Double? {
        twoFingersSince = twoFingers ? (twoFingersSince ?? t) : nil
        pointingSince = pointing ? (pointingSince ?? t) : nil
        if !isScrolling, let twoFingersSince, t - twoFingersSince >= hold {
            isScrolling = true
            stroke = .bend
            switching = nil
            heading = 1
            extreme = nil
            rest = nil
            moving = false
            recent = []
            momentum = nil
        }
        if isScrolling, let pointingSince, t - pointingSince >= release {
            isScrolling = false
            switching = nil
        }
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

    /// 回傳這一下捲動的距離（pt）。
    private mutating func track(_ height: Double, at t: Double) -> Double {
        // 離開起點的方向：起點在伸直端時往下。
        let away = stroke == .bend ? -1.0 : 1.0
        var delta = 0.0
        var advanced = false
        if let extreme {
            let reversed = (extreme - height) * heading >= reversal
            if reversed { heading = -heading }
            if reversed || (height - extreme) * heading > 0 {
                if heading == away {
                    delta = (height - extreme) * scale
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
        // 停在另一端 `dwell` 秒：起點換到這一端。
        if let rest, abs(height - rest.height) <= stillness {} else { rest = (height, t) }
        if heading == away, let rest {
            let progress = (t - rest.t) / dwell
            if progress >= 1 {
                stroke = heading > 0 ? .bend : .straighten
                switching = nil
            } else {
                switching = progress
            }
        } else {
            switching = nil
        }
        recent.removeAll { $0.t < t - 2 * flickWindow }
        recent.append((height, t))
        return delta
    }

    /// 這一下停住：依最後 `flickWindow` 秒（到上一幀為止）的速度開始慣性。
    private mutating func flick() {
        guard let last = recent.last, let start = recent.last(where: { $0.t <= last.t - flickWindow }) ?? recent.first,
              last.t > start.t else { return }
        let velocity = (last.height - start.height) / (last.t - start.t) * scale
        if velocity * (stroke == .bend ? -1 : 1) >= flickSpeed { momentum = (velocity, last.t) }
    }
}
