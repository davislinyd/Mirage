/// 捏合 → 滑鼠左鍵：確認捏合（`PinchClickDetector`）時按下，手指張開或看不到手超過 `lostRelease` 秒時放開。
/// 按住 `dragDelay` 秒後游標才跟著手移動（拖曳）；三份錄影中快速點擊的捏合最長約 0.33 秒。
///
/// 從食指指向的姿勢捏合時，食指尖會往拇指移動，游標跟著偏移。所以捏合比例比最近 `peakWindow` 秒內的最大值
/// 低 `drop` 以上時，游標凍結在最大值那一幀的位置，點擊落在捏合前指著的地方（三份錄影中誤差中位數約 19 pt）。
/// 手在移動時（食指根部速度達 `calmSpeed`）比例也會抖動，此時不凍結，以免移動中游標卡住。放開後維持凍結，
/// 直到比例回到凍結前的 `recover` 倍，因為張開手指時食指尖同樣會移動。
public struct PinchClicker: Sendable {
    public enum Button: Sendable, Equatable {
        case down, up
    }

    public struct Output: Sendable {
        /// 要顯示的游標位置。
        public var cursor: Vec2?
        public var button: Button?
    }

    public var drop = 0.2
    public var peakWindow = 0.3
    /// 正規化影像座標／秒：最近 `speedWindow` 秒內食指根部移動的路徑長 ÷ 時間。
    public var calmSpeed = 0.5
    public var speedWindow = 0.2
    public var recover = 0.9
    /// 沒按著時，凍結最多維持的秒數。
    public var maxFreeze = 1.0
    public var dragDelay = 0.5
    /// 拖曳時比例低於此值才移動：放開途中手指張開，食指尖也會移動，不能把放下的位置帶偏。
    public var dragRatio = 0.3
    public var lostRelease = 0.3

    private var click = PinchClickDetector()
    /// 最近 `peakWindow` 秒內量得到比例與游標的幀。
    private var history: [(t: Double, ratio: Double, cursor: Vec2, calm: Bool)] = []
    private var anchors: [(t: Double, point: Vec2)] = []
    private var lastRatio: Double?
    /// 比例連續上升的幀數。
    private var rises = 0
    private var lastSeen = 0.0
    /// `pinched`：這次凍結後確認過捏合。沒確認過時，比例連續上升兩幀就解除（只是比例抖動）。
    private var frozen: (cursor: Vec2, peak: Double, t: Double, pinched: Bool)?
    private var pressedAt: Double?
    /// `from`：開始拖曳時手指對應的游標位置。
    private var drag: (from: Vec2, position: Vec2)?

    public var isPressed: Bool { pressedAt != nil }

    public init() {}

    /// `cursor`：這一幀手指對應的游標位置；`ratio`：捏合比例；`anchor`：食指根部（正規化影像座標）；
    /// `valid`：同 `PinchClickDetector`。
    public mutating func update(cursor: Vec2?, ratio: Double?, anchor: Vec2?, valid: Bool, at t: Double) -> Output {
        if let anchor { anchors.append((t, anchor)) }
        anchors.removeAll { t - $0.t > speedWindow }
        let path = zip(anchors, anchors.dropFirst()).reduce(0.0) { $0 + $1.0.point.distance(to: $1.1.point) }
        let span = (anchors.last?.t ?? 0) - (anchors.first?.t ?? 0)
        let calm = span > 0 ? path / span < calmSpeed : true
        if let ratio {
            rises = lastRatio.map { ratio > $0 } == true ? rises + 1 : 0
            lastRatio = ratio
            lastSeen = t
            if let cursor { history.append((t, ratio, cursor, calm)) }
        }
        history.removeAll { t - $0.t > peakWindow }

        let confirmed = click.update(ratio: ratio, valid: valid)
        if frozen == nil, let ratio, let peak = history.max(by: { $0.ratio < $1.ratio }),
           confirmed || (peak.calm && ratio < peak.ratio * (1 - drop)) {
            frozen = (peak.cursor, peak.ratio, t, false)
        }
        var button: Button?
        if confirmed, frozen != nil {
            frozen?.pinched = true
            pressedAt = t
            button = .down
        } else if let pressedAt {
            if !click.isPinched || t - lastSeen > lostRelease {
                button = .up
                frozen?.t = t
                if let drag { frozen?.cursor = drag.position }
                self.pressedAt = nil
                drag = nil
            } else {
                if drag == nil, t - pressedAt >= dragDelay, let cursor, let base = frozen?.cursor { drag = (cursor, base) }
                if let from = drag?.from, let base = frozen?.cursor, let cursor, let ratio, ratio <= dragRatio {
                    drag?.position = Vec2(x: base.x + cursor.x - from.x, y: base.y + cursor.y - from.y)
                }
            }
        }
        if let frozen, pressedAt == nil {
            let back = ratio.map { $0 >= frozen.peak * recover } ?? false
            if back || (!frozen.pinched && rises >= 2) || t - frozen.t > maxFreeze { self.frozen = nil }
        }
        return Output(cursor: drag?.position ?? frozen?.cursor ?? cursor, button: button)
    }
}
