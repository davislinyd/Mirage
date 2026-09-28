/// 按鍵式點擊 → 滑鼠左鍵：`TapDetector` 確認按下時按下，食指伸直回來、姿勢不對或看不到手超過 `lostRelease` 秒時
/// 放開。按住 `dragDelay` 秒後游標才跟著手移動（拖曳）。
///
/// 按下時指尖兩節會動，指根與 PIP 也會跟著晃（錄影中 PIP p90 0.12 掌寬），游標跟著偏移。所以確認按下時，點擊落在
/// 最近 `TapDetector.window` 秒內彎曲量最小那一幀的游標位置，也就是開始按之前指著的地方。彎曲量一比最小值多
/// `onset` 度、而且手掌不動（速度低於 `calmSpeed` 掌寬／秒），就提前凍結在那個位置，不讓游標在按下前先跟著偏；
/// 手一動就解除。沒有形成按下時，彎曲量連續下降兩幀或凍結超過 `pending` 秒就解除；放開後再維持 `settle` 秒，因為
/// 伸直回來時食指同樣會動，雙擊的第二下也會落在同一點。
public struct TapClicker: Sendable {
    public enum Button: Sendable, Equatable {
        case down, up
    }

    public struct Output: Sendable {
        /// 要顯示的游標位置。
        public var cursor: Vec2?
        public var button: Button?
    }

    /// 度。懸停與慢速對準時，彎曲量 0.3 秒內的上升 p99 約 7°。
    public var onset = 10.0
    /// 掌寬／秒：最近 `speedWindow` 秒內手掌的淨位移 ÷ 時間。
    public var calmSpeed = 0.3
    public var speedWindow = 0.2
    public var pending = 0.4
    public var settle = 0.25
    public var dragDelay = 0.5
    public var lostRelease = 0.3

    private var tap = TapDetector()
    /// 最近 `TapDetector.window` 秒內、姿勢正確而且量得到彎曲量與游標的幀（同 `TapDetector`，姿勢不對的幀只跳過）。
    private var history: [(t: Double, flex: Double, cursor: Vec2, calm: Bool)] = []
    /// 手掌中心（以校準掌寬為單位的像素座標）。
    private var palms: [(t: Double, point: Vec2)] = []
    private var lastFlex: Double?
    /// 彎曲量連續下降的幀數。
    private var falls = 0
    private var lastSeen = 0.0
    /// `pressed`：這次凍結後確認過按下。
    private var frozen: (cursor: Vec2, t: Double, pressed: Bool)?
    private var pressedAt: Double?
    /// `from`：開始拖曳時手指對應的游標位置。
    private var drag: (from: Vec2, position: Vec2)?

    public var isPressed: Bool { pressedAt != nil }
    /// 最近一幀量到的手掌速度（掌寬／秒）。
    public private(set) var palmSpeed: Double?

    public init() {}

    /// `cursor`：這一幀手指對應的游標位置；`flex`、`height`、`middle`、`posed`：同 `TapDetector`；`palm`：手掌中心，
    /// 以校準掌寬為單位；`valid`：手的大小符合，不符時不按下。
    public mutating func update(
        cursor: Vec2?, flex: Double?, height: Double?, middle: Double?, posed: Bool, palm: Vec2?, valid: Bool, at t: Double
    ) -> Output {
        if let palm { palms.append((t, palm)) }
        palms.removeAll { t - $0.t > speedWindow }
        var speed: Double?
        if let first = palms.first, let last = palms.last, last.t > first.t {
            speed = first.point.distance(to: last.point) / (last.t - first.t)
        }
        palmSpeed = speed
        // 還量不到速度（剛看到手）時不當作平穩。
        let calm = speed.map { $0 < calmSpeed } ?? false
        if let flex {
            falls = lastFlex.map { flex < $0 } == true ? falls + 1 : 0
            lastFlex = flex
            lastSeen = t
            if posed, let cursor { history.append((t, flex, cursor, calm)) }
        }
        history.removeAll { t - $0.t > tap.window }

        let confirmed = tap.update(flex: flex, height: height, middle: middle, posed: posed, palmSpeed: speed, at: t) && valid
        // 最小值有好幾幀時取最後一幀：開始按之前的最後一刻。
        let low = history.map(\.flex).min()
        if frozen == nil, posed, let flex, let rest = history.last(where: { $0.flex == low }),
           confirmed || (rest.calm && calm && flex >= rest.flex + onset) {
            frozen = (rest.cursor, t, false)
        }
        var button: Button?
        if confirmed, frozen != nil {
            frozen?.pressed = true
            pressedAt = t
            button = .down
            // 按下前的最小值用完了：留著的話，放開後一解凍，又會因為彎曲量比它大而凍回這個位置。
            history = []
        } else if let pressedAt {
            if !tap.isPressed || t - lastSeen > lostRelease {
                button = .up
                frozen?.t = t
                if let drag { frozen?.cursor = drag.position }
                self.pressedAt = nil
                drag = nil
            } else {
                if drag == nil, t - pressedAt >= dragDelay, let cursor, let base = frozen?.cursor { drag = (cursor, base) }
                // 還按著才移動：伸直回來途中食指也會動，不能把放下的位置帶偏。
                if let from = drag?.from, let base = frozen?.cursor, let cursor, let flex, flex - tap.base >= tap.rise {
                    drag?.position = Vec2(x: base.x + cursor.x - from.x, y: base.y + cursor.y - from.y)
                }
            }
        }
        if let frozen, pressedAt == nil {
            let settled = frozen.pressed ? t - frozen.t >= settle : falls >= 2 || t - frozen.t > pending
            if settled || !calm { self.frozen = nil }
        }
        return Output(cursor: drag?.position ?? frozen?.cursor ?? cursor, button: button)
    }
}
