/// 兩指捲動：食指與中指一起伸直 `hold` 秒後進入捲動（游標停住），之後彎、伸兩指來捲；只有食指伸直持續 `release`
/// 秒才離開。捲動訊號是食指尖比食指根高出幾個掌寬（`height`），整隻手移動時不變。
///
/// 高度低於 `bent` 算彎曲端、高於 `extended` 算伸直端，兩者之間維持原本那一端（遲滯）。手指在同一端停留
/// `dwell` 秒，那一端就成為起點：離開起點的那一下捲動，距離是指尖高度的變化 × `scale`，內容跟著指尖移動；
/// 回到起點的那一下不捲。錄影中彎、伸的速度沒有一致的差別，無法從動作本身分辨哪一下是滑過去、哪一下是收回來，
/// 所以用停留的位置分辨。進入捲動時兩指伸直，每彎一下，內容往下移一段；彎著停 `dwell` 秒後改成每伸直一下，
/// 內容往上移一段；再伸直停 `dwell` 秒就換回來。錄影中兩下之間彎著最久約 0.8 秒。
///
/// 捏合（右鍵）不算一下：四份錄影捏合階段（只有食指伸直）的 42 次點擊，食指尖最低多在 0.3 掌寬以上，只有 2 次
/// 低於 `bent`。
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
    public var bent = 0.2
    public var extended = 0.4
    public var dwell = 1.0
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

    private var twoFingersSince: Double?
    private var pointingSince: Double?
    /// 手指在伸直端（否則在彎曲端），與進入這一端的時間。
    private var straight = true
    private var since = 0.0
    /// 在這一端到過最遠的高度：伸直端取最高、彎曲端取最低。
    private var extreme: Double?
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
            straight = true
            since = t
            extreme = nil
            moving = false
            recent = []
            momentum = nil
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

    /// 回傳這一下捲動的距離（pt）。
    private mutating func track(_ height: Double, at t: Double) -> Double {
        let switched = straight ? height < bent : height > extended
        if switched {
            straight.toggle()
            since = t
        }
        // 手指在離開起點的那一端。
        let away = straight == (stroke == .straighten)
        var delta = 0.0
        var advanced = false
        if switched || extreme.map({ straight ? height > $0 : height < $0 }) ?? true {
            if away, let extreme {
                delta = (height - extreme) * scale
                advanced = true
            }
            extreme = height
        }
        if advanced {
            moving = true
            momentum = nil
        } else if moving {
            moving = false
            flick()
        }
        if t - since >= dwell { stroke = straight ? .bend : .straighten }
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
