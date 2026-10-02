/// 三指揮動：食指、中指與無名指一起伸直 `hold` 秒後進入三指模式（游標停住）。手掌快速往左、往右或往上一揮，就回傳
/// 要去的桌面方向，同觸控板的三指滑動：手往右揮去左邊的桌面（⌃←），往左揮去右邊的桌面（⌃→），往上揮開 Mission
/// Control（⌃↑）；往下不算。三指以外的姿勢持續 `release` 秒才離開。
///
/// 手掌的位置不管有沒有進入三指模式都持續記錄：往上揮是抬手的同時才伸出三指，姿勢只比速度峰值早 0.03–0.07 秒，
/// 進入模式才開始記位置，三幀的速度要等到揮完了才算得出來。
///
/// 揮完手要收回來，回程看起來就是另一個方向的揮動，靠速度與時間擋：慢慢收回達不到門檻；一揮之後 `refractory` 秒內
/// 不接受不同的方向。一揮的速度常有起伏，所以觸發後速度要先降到 `rearm` 以下，同方向也要隔 `cooldown` 秒，才不會
/// 一揮換掉兩個桌面。
///
/// 門檻用兩份 `desktop` 錄影（`recordings/desktop-2026-10-01T05-22-20Z`、`05-42-40Z`）定的，還沒用第三份驗證。三指階段
/// 的手掌速度（三幀頭尾，掌寬/秒）：刻意的一揮峰值，往右 3.6–9.8、往左 3.5–8.2、往上 3.1–6.5；揮完慢慢收回 ≤ 4.4，往
/// 上揮的回程 ≤ 2.5，往下揮的回程 ≤ 3.6；要求慢慢移動的階段，第一份 ≤ 3.7，第二份移得比較快，到 5.9（約 1.5 個掌寬、
/// 0.4–0.5 秒，和刻意的一揮重疊，只能降低誤觸）。重播（第一份、第二份）：往右揮 6/10、15 下（第二份揮了約 14 下）、往左
/// 7/10、7 下（約 12 下）、往上 5/10、7 下（約 13 下）；慢慢移動階段誤觸 0 次與 3 次，其他階段 0 次。
public struct DesktopSwiper: Sendable {
    /// 要去的桌面方向。
    public enum Direction: Sendable, Equatable {
        /// ⌃←：手往右揮。
        case left
        /// ⌃→：手往左揮。
        case right
        /// ⌃↑：手往上揮，Mission Control。
        case up
    }

    /// 秒：三指要維持這麼久才進入，約連續兩幀。往上揮是抬手途中才伸出三指，往左揮時三指只在動作開頭出現 1–2 幀、無名指
    /// 隨後就收起來，不能要求先停一下（原本 0.3 秒，往上揮完全抓不到）；日常錄影中偶爾會有 0.17–0.4 秒的三指姿勢，
    /// 所以還是要有夠快的一揮才送。0（一幀）會在日常多出 1 次誤觸。
    public var hold = 0.03
    /// 只有三指以外的姿勢持續此秒數才離開：手揮得快時，手指常有 1–2 幀被誤判，無名指收起的時間更長。
    public var release = 0.3
    /// 掌寬/秒：手掌中心往左或往右的速度。5.0 時第二份的慢慢移動階段誤觸 3 次；4.5 是 6 次，6.0 是 0 次、但往右往左各少抓
    /// 約 2–4 下。
    public var sideSpeed = 5.0
    /// 掌寬/秒：手掌中心往上的速度。抬手比左右揮慢，刻意的一揮 3.9–5.3，慢慢往上移動最快 3.7：4.0 抓到約 4/10。
    public var upSpeed = 4.0
    /// 主軸的速度須是另一軸的此倍以上：斜著揮不算。
    public var dominance = 2.0
    /// 掌寬/秒：觸發後速度降到此值以下，才能再觸發。
    public var rearm = 2.0
    /// 秒：同方向再觸發的最短間隔。
    public var cooldown = 0.5
    /// 秒：觸發後，不同方向在這段時間內不算。實機試用時 1.2 秒（同 `Scroller`）要等太久，反向揮了沒反應，改成 0.5 秒，
    /// 還沒用錄影量過快速回程出現的時間。
    public var refractory = 0.5
    /// 秒：兩幀間隔超過此值，算出來的速度不可信，重新累積。
    public var maxGap = 0.2

    /// 三指模式中：游標停住，不點擊。
    public private(set) var isActive = false

    private var threeSince: Double?
    private var otherSince: Double?
    /// 最近三幀的手掌中心：速度取頭尾兩幀，比單幀穩。
    private var history: [(point: Vec2, t: Double)] = []
    private var armed = true
    private var last: (direction: Direction, t: Double)?

    public init() {}

    /// `threeFingers`：食指、中指與無名指伸直、小指收起；`position`：手掌中心（掌寬，x 往使用者的右邊為正、y 往上為正），
    /// 量不到時為 nil。回傳這一幀要去的桌面方向。
    public mutating func update(threeFingers: Bool, position: Vec2?, at t: Double) -> Direction? {
        threeSince = threeFingers ? (threeSince ?? t) : nil
        otherSince = threeFingers ? nil : (otherSince ?? t)
        if !isActive, let threeSince, t - threeSince >= hold { isActive = true }
        if isActive, let otherSince, t - otherSince >= release { isActive = false }
        guard let position else { return nil }
        if let previous = history.last, t - previous.t > maxGap { history = [] }
        history.append((position, t))
        if history.count > 3 { history.removeFirst() }
        guard isActive, history.count == 3, t > history[0].t else { return nil }
        let vx = (position.x - history[0].point.x) / (t - history[0].t)
        let vy = (position.y - history[0].point.y) / (t - history[0].t)
        guard armed else {
            armed = vx * vx + vy * vy < rearm * rearm
            return nil
        }
        let direction: Direction
        if vx >= sideSpeed, vx >= dominance * vy.magnitude {
            direction = .left
        } else if vx <= -sideSpeed, -vx >= dominance * vy.magnitude {
            direction = .right
        } else if vy >= upSpeed, vy >= dominance * vx.magnitude {
            direction = .up
        } else {
            return nil
        }
        if let last, t - last.t < (last.direction == direction ? cooldown : refractory) { return nil }
        last = (direction, t)
        armed = false
        return direction
    }
}
