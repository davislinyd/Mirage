/// 游標控制的啟用狀態。
public enum ControlState: Sendable, Equatable {
    /// 只偵測喚醒手勢。
    case idle
    /// 已喚醒，等待食指指向。
    case armed
    /// 游標跟隨食指尖。
    case active
}

/// 啟用狀態機。Idle 只看喚醒手勢；喚醒後進入 Armed，`armTimeout` 秒內在操作範圍內食指指向並維持 `pointHold`
/// 秒才進入 Active。三份錄影的日常誤喚醒都是真的張手 → 握拳（伸手拿東西），之後沒有接著指向，會在 Armed 逾時。
/// Active 時看不到手超過 `lostTimeout` 秒，或看得到手、但離開操作範圍超過 `outsideTimeout` 秒，回到 Idle，
/// 須重新喚醒。
public struct ControlStateMachine: Sendable {
    public var armTimeout = 3.0
    public var pointHold = 0.2
    public var lostTimeout = 2.0
    public var outsideTimeout = 1.0
    public private(set) var state = ControlState.idle
    private var armedAt = 0.0
    private var pointingSince: Double?
    private var lastSeen = 0.0
    private var lastInside = 0.0

    public init() {}

    /// `visible`：看得到手且大小符合；`inside`：手在操作範圍內；`pointing`：在操作範圍內食指指向。
    public mutating func update(woke: Bool, pointing: Bool, visible: Bool, inside: Bool, at t: Double) -> ControlState {
        if visible { lastSeen = t }
        if inside { lastInside = t }
        // Armed 時再喚醒一次重新計時。
        if woke, state != .active {
            state = .armed
            armedAt = t
            pointingSince = nil
        }
        switch state {
        case .idle:
            break
        case .armed:
            pointingSince = pointing ? (pointingSince ?? t) : nil
            if let pointingSince, t - pointingSince >= pointHold {
                state = .active
            } else if t - armedAt > armTimeout {
                state = .idle
            }
        case .active:
            let left = visible ? t - lastInside > outsideTimeout : t - lastSeen > lostTimeout
            if left { state = .idle }
        }
        return state
    }

    public mutating func reset() {
        state = .idle
    }
}

/// 主要手 → 啟用狀態 → 游標位置（螢幕 pt，原點左下）、左鍵與捲動。只有 Active 時輸出游標、左鍵與捲動。
public struct CursorController: Sendable {
    public struct Output: Sendable {
        public var state: ControlState
        public var cursor: Vec2?
        public var button: PinchClicker.Button?
        /// 這一幀要捲動的 pt，內容往上為正。
        public var scroll: Double?
    }

    public let calibration: Calibration
    public let screenWidth: Double
    public let screenHeight: Double
    /// 掌寬須在校準值的此範圍內才算數。側手、離太遠或太近的手，以及背後旁人的手，量到的掌寬都會明顯偏離。
    public var palmRange = 0.6...1.4
    /// 量不到掌寬時，沿用此秒數內最近一次量到的值（同 `GestureProbe.palmHold`）。
    public var palmHold = 0.2
    /// 手消失超過此秒數後重置濾波器，避免游標從舊位置慢慢滑過去。
    public var resetGap = 0.2
    /// 操作範圍：校準範圍往四周各擴大其寬高的此倍數。手超出校準範圍時游標停在螢幕邊緣，超出操作範圍視為離開。
    public var reachMargin = 0.5
    /// 依速度往前外插的秒數，補償部分相機延遲。三份錄影中 33 ms 讓移動時的誤差少約 1/4，靜止抖動 p50 只多約 0.5 pt。
    public var lead = 0.033

    private var machine = ControlStateMachine()
    private var wake = WakeDetector()
    private var clicker = PinchClicker()
    private var scroller = Scroller()
    /// 上一幀輸出的游標：捲動時游標停在這裡。
    private var lastCursor: Vec2?
    private var filter = OneEuroFilter2D()
    private var velocity = Vec2(x: 0, y: 0)
    private var last: (point: Vec2, t: Double)?
    private var lastPalm: (width: Double, t: Double)?

    public init(calibration: Calibration, screenWidth: Double, screenHeight: Double) {
        self.calibration = calibration
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }

    public mutating func update(hands: [Hand], width: Int, height: Int, at t: Double) -> Output {
        let geometry = hands.primary.map { HandGeometry(hand: $0, width: width, height: height) }
        let measuredPalm = geometry?.palmWidth
        if let measuredPalm { lastPalm = (measuredPalm, t) }
        let palm = measuredPalm ?? lastPalm.flatMap { t - $0.t <= palmHold ? $0.width : nil }
        let sized = palm.map { palmRange.contains($0 / calibration.palmWidth) } ?? false
        let woke = wake.update(pose: sized ? geometry?.pose : .other, at: t)
        let tip = sized ? geometry?.normalized(.indexTip) : nil
        let inside = tip.map { isInside($0) } ?? false
        let pointing = inside && geometry?.isPointing(palmWidth: palm ?? 0) == true
        let state = machine.update(woke: woke, pointing: pointing, visible: tip != nil, inside: inside, at: t)
        var cursor: Vec2?
        if let tip {
            if let last, t - last.t > resetGap {
                filter.reset()
                velocity = Vec2(x: 0, y: 0)
                self.last = nil
            }
            let filtered = filter(map(tip), at: t)
            if let last, t > last.t {
                velocity.x += 0.5 * ((filtered.x - last.point.x) / (t - last.t) - velocity.x)
                velocity.y += 0.5 * ((filtered.y - last.point.y) / (t - last.t) - velocity.y)
            }
            last = (filtered, t)
            cursor = clamp(Vec2(x: filtered.x + velocity.x * lead, y: filtered.y + velocity.y * lead))
        }
        guard state == .active else {
            clicker = PinchClicker()
            scroller = Scroller()
            return Output(state: state, cursor: nil)
        }
        let twoFingers = inside && !clicker.isPressed && geometry?.isPointing(palmWidth: palm ?? 0, fingers: 2) == true
        // 與游標同比例、不限制在螢幕內，手超出校準範圍時仍能捲動。
        let knuckle = sized ? geometry?.normalized(.indexMCP) : nil
        let y = knuckle.map { ($0.y - calibration.minY) / (calibration.maxY - calibration.minY) * screenHeight }
        let scroll = scroller.update(twoFingers: twoFingers, pointing: pointing, y: y, at: t)
        if scroller.isScrolling {
            clicker = PinchClicker()
            return Output(state: state, cursor: lastCursor, scroll: scroll)
        }
        // 用沿用的掌寬：捏合時拇指常擋住食指根部。
        var ratio: Double?
        if sized, let palm, let gap = geometry?.distance(.thumbTip, .indexTip) { ratio = gap / palm }
        // 食指彎曲代表握拳或拿東西，不是捏合；關節不確定時不擋，以免漏掉真的捏合。
        let click = clicker.update(
            cursor: cursor, ratio: ratio, anchor: sized ? geometry?.normalized(.indexMCP) : nil,
            valid: sized && geometry?.indexCurled != true, at: t
        )
        lastCursor = click.cursor
        return Output(state: state, cursor: click.cursor, button: click.button, scroll: scroll)
    }

    /// 快捷鍵、螢幕鎖定等外部原因停用：回到 Idle，須重新喚醒。
    public mutating func deactivate() {
        machine.reset()
    }

    private func isInside(_ p: Vec2) -> Bool {
        let c = calibration
        let dx = (c.maxX - c.minX) * reachMargin
        let dy = (c.maxY - c.minY) * reachMargin
        return p.x >= c.minX - dx && p.x <= c.maxX + dx && p.y >= c.minY - dy && p.y <= c.maxY + dy
    }

    /// 校準範圍 → 螢幕，水平鏡像：手往右移，游標也往右。
    private func map(_ p: Vec2) -> Vec2 {
        let c = calibration
        return clamp(Vec2(
            x: (c.maxX - p.x) / (c.maxX - c.minX) * screenWidth,
            y: (p.y - c.minY) / (c.maxY - c.minY) * screenHeight
        ))
    }

    private func clamp(_ p: Vec2) -> Vec2 {
        Vec2(x: min(max(p.x, 0), screenWidth), y: min(max(p.y, 0), screenHeight))
    }
}
