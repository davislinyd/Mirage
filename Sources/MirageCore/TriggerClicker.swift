/// 扳機 → 滑鼠左鍵：`TriggerDetector` 確認按下時按下，拇指抬起、食指彎下或看不到手超過 `lostRelease` 秒時放開。
/// 按住 `dragDelay` 秒後游標才跟著手移動（拖曳）。
///
/// 拇指往下壓時食指與整隻手都會跟著動，游標跟著偏移：錄影中不鎖定的話，點擊會偏 p50 42–67 pt。所以確認按下時，
/// 點擊落在最近 `TriggerDetector.window` 秒內拇指距離最高那一幀的游標位置，也就是拇指開始動之前指著的地方。
///
/// 為了不讓游標在按下前先跟著偏，拇指距離一比最高點低 `onset`，就提前凍結在那個位置。但一般移動游標時拇指也會晃，
/// 只看 `onset` 時，錄影中移動階段有 24% 的時間被凍結，游標一頓一頓。所以提前凍結還要拇指已靠近食指（距離在
/// `approach` 以下）而且手幾乎不動（食指根部速度低於 `calmSpeed`）：錄影中扳機開始時距離 p90 0.55、速度 p90
/// 0.12，移動時拇指晃動的距離 p50 0.71、速度 p50 0.24。這樣移動時凍結降到約 2%，39 下扳機仍有 37 下提前鎖住。
/// 手一動就解除凍結。沒有形成按下時，距離連續上升兩幀
/// 或凍結超過 `pending` 秒就解除；放開後再維持 `settle` 秒，因為抬起時食指同樣會動，雙擊的第二下也會落在同一點。
/// 拇指常抬不回第一次壓下前的高度，所以不能等它抬回最高點才解除。
public struct TriggerClicker: Sendable {
    public enum Button: Sendable, Equatable {
        case down, up
    }

    public struct Output: Sendable {
        /// 要顯示的游標位置。
        public var cursor: Vec2?
        public var button: Button?
    }

    public var onset = 0.06
    public var approach = 0.55
    /// 正規化影像座標／秒：最近 `speedWindow` 秒內食指根部移動的路徑長 ÷ 時間。
    public var calmSpeed = 0.2
    public var speedWindow = 0.2
    public var pending = 0.4
    public var settle = 0.25
    public var dragDelay = 0.5
    public var lostRelease = 0.3

    private var trigger = TriggerDetector()
    /// 食指伸直期間、最近 `TriggerDetector.window` 秒內量得到距離與游標的幀。
    private var history: [(t: Double, distance: Double, cursor: Vec2, calm: Bool)] = []
    private var anchors: [(t: Double, point: Vec2)] = []
    private var lastDistance: Double?
    /// 距離連續上升的幀數。
    private var rises = 0
    private var lastSeen = 0.0
    /// `pressed`：這次凍結後確認過按下。
    private var frozen: (cursor: Vec2, peak: Double, t: Double, pressed: Bool)?
    private var pressedAt: Double?
    /// `from`：開始拖曳時手指對應的游標位置。
    private var drag: (from: Vec2, position: Vec2)?

    public var isPressed: Bool { pressedAt != nil }

    public init() {}

    /// `cursor`：這一幀手指對應的游標位置；`distance`、`rise`、`posed`：同 `TriggerDetector`；`anchor`：食指根部
    /// （正規化影像座標）；`valid`：手的大小符合，不符時不按下。
    public mutating func update(
        cursor: Vec2?, distance: Double?, rise: Double?, posed: Bool, anchor: Vec2?, valid: Bool, at t: Double
    ) -> Output {
        if let anchor { anchors.append((t, anchor)) }
        anchors.removeAll { t - $0.t > speedWindow }
        let path = zip(anchors, anchors.dropFirst()).reduce(0.0) { $0 + $1.0.point.distance(to: $1.1.point) }
        let span = (anchors.last?.t ?? 0) - (anchors.first?.t ?? 0)
        // 還量不到速度（剛看到手）時不當作平穩。
        let calm = span > 0 && path / span < calmSpeed
        let straight = posed && (rise ?? trigger.straight) >= trigger.straight
        if let distance {
            rises = lastDistance.map { distance > $0 } == true ? rises + 1 : 0
            lastDistance = distance
            lastSeen = t
            if !straight {
                history = []
            } else if let cursor {
                history.append((t, distance, cursor, calm))
            }
        }
        history.removeAll { t - $0.t > trigger.window }

        let confirmed = trigger.update(distance: distance, rise: rise, posed: posed, at: t) && valid
        // 最高點有好幾幀時取最後一幀：拇指開始往下之前的最後一刻。
        let top = history.map(\.distance).max()
        if frozen == nil, straight, let distance, let peak = history.last(where: { $0.distance == top }),
           confirmed || (peak.calm && calm && distance <= min(approach, peak.distance - onset)) {
            frozen = (peak.cursor, peak.distance, t, false)
        }
        var button: Button?
        if confirmed, frozen != nil {
            frozen?.pressed = true
            pressedAt = t
            button = .down
            // 按下前的最高點用完了：留著的話，放開後一解凍，又會因為距離比它低而凍回這個位置。
            history = []
        } else if let pressedAt {
            if !trigger.isPressed || t - lastSeen > lostRelease {
                button = .up
                frozen?.t = t
                if let drag { frozen?.cursor = drag.position }
                self.pressedAt = nil
                drag = nil
            } else {
                if drag == nil, t - pressedAt >= dragDelay, let cursor, let base = frozen?.cursor { drag = (cursor, base) }
                // 拇指還壓著才移動：抬起途中食指也會動，不能把放下的位置帶偏。
                if let from = drag?.from, let base = frozen?.cursor, let cursor, let distance,
                   distance - trigger.low <= trigger.lift / 2 {
                    drag?.position = Vec2(x: base.x + cursor.x - from.x, y: base.y + cursor.y - from.y)
                }
            }
        }
        if let frozen, pressedAt == nil {
            let back = distance.map { $0 >= frozen.peak - onset / 2 } ?? false
            let settled = frozen.pressed ? t - frozen.t >= settle : rises >= 2 || t - frozen.t > pending
            if back || settled || !calm { self.frozen = nil }
        }
        return Output(cursor: drag?.position ?? frozen?.cursor ?? cursor, button: button)
    }
}
