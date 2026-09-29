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

    /// 錄影重播用：略過喚醒，直接進入 Active。
    mutating func activate(at t: Double) {
        state = .active
        lastSeen = t
        lastInside = t
    }
}

/// 控制中的操作模式，給 HUD 顯示。
public enum ControlMode: Sendable, Equatable {
    /// 只伸食指：移動游標、按鍵點擊、扳機右鍵。
    case pointing
    /// 左鍵按著：移動手就拖曳。
    case pressing
    /// 兩指捲動，值為目前內容移動的方向。
    case scrolling(Scroller.Direction)
    /// 扳機按住：手往上放大、往下縮小。
    case zooming
}

/// 主要手 → 啟用狀態 → 游標位置（螢幕 pt，原點左下）、左右鍵與捲動。只有 Active 時輸出。
public struct CursorController: Sendable {
    public struct Output: Sendable, Equatable {
        public var state: ControlState
        public var cursor: Vec2?
        public var button: TapClicker.Button?
        /// 這一幀要捲動的 pt，指尖往上為正，內容跟著指尖移動。
        public var scroll: Double?
        /// 右鍵單擊：只伸食指時的扳機，拇指抬起時送出。
        public var rightClick = false
        /// 按一下 ESC：兩指捲動時的扳機。
        public var escape = false
        /// 捲動中（游標停住）時為目前內容移動的方向，否則為 nil。
        public var scrolling: Scroller.Direction?
        /// 食指尖比指根高出幾個掌寬，供動作紀錄查捲動。
        public var rise: Double?
        /// 這一幀要縮放的格數：放大為正（⌘=），縮小為負（⌘−）。
        public var zoom: Int?
        /// 扳機按住超過 `zoomDelay` 秒，手上下移動就縮放；游標停在按下前的位置。
        public var zooming = false
        /// 左鍵按著（按鍵按住或拖曳中）。
        public var pressed = false

        /// HUD 顯示的操作模式；不在控制中時為 nil。
        public var mode: ControlMode? {
            guard state == .active else { return nil }
            if zooming { return .zooming }
            if let scrolling { return .scrolling(scrolling) }
            return pressed ? .pressing : .pointing
        }
    }

    public let calibration: Calibration
    public let screenWidth: Double
    public let screenHeight: Double
    /// 掌寬須在校準值的此範圍內才算數。側手、離太遠或太近的手，以及背後旁人的手，量到的掌寬都會明顯偏離。
    /// 手放低時，校準畫圈時手掌斜著、量到的較小，做手勢時正對鏡頭可到 1.44 倍，所以上限放寬到 1.6。
    public var palmRange = 0.6...1.6
    /// 量不到掌寬時，沿用此秒數內最近一次量到的值（同 `GestureProbe.palmHold`）。
    public var palmHold = 0.2
    /// 手消失超過此秒數後重置濾波器，避免游標從舊位置慢慢滑過去。
    public var resetGap = 0.2
    /// 操作範圍：校準範圍往四周各擴大其寬高的此倍數。手超出校準範圍時游標停在螢幕邊緣，超出操作範圍視為離開。
    public var reachMargin = 0.5
    /// 依速度往前外插的秒數，補償部分相機延遲。三份錄影中 33 ms 讓移動時的誤差少約 1/4，靜止抖動 p50 只多約 0.5 pt。
    public var lead = 0.033
    /// 開始捲動時，游標回到此秒數內最後一次只有食指指向時的位置：伸直中指時食指尖也會跟著動。
    public var pointMemory = 0.5
    /// 扳機按住超過此秒數就是縮放，放開也不送右鍵。錄影中一般的扳機按住 0.1–0.4 秒，刻意按住 0.6–1.2 秒。
    public var zoomDelay = 0.5
    /// pt：縮放時，手每上下移動這麼多（以游標的比例換算，不受螢幕邊緣限制）縮放一格。
    public var zoomStep = 150.0
    /// 掌寬／秒：手掌速度低於此值，拇指扳機才算右鍵或 ESC。移動游標時拇指也會晃，錄影中每 10 秒約誤觸 1 次；但扳機時
    /// 整隻手也會跟著動，比按鍵點擊時快：0.3 會漏掉大半，0.8 只漏 3/41 下，移動時誤觸剩 1/2。兩指時手往上抬也會
    /// 誤觸 ESC（1.6–2.9），兩指扳機 124 下只有 4 下超過 0.8。
    public var triggerStillSpeed = 0.8

    private var machine = ControlStateMachine()
    private var operatorLock = OperatorLock()
    private var wake = WakeDetector()
    private var clicker = TapClicker()
    private var scroller = Scroller()
    /// 只伸食指時的扳機 = 右鍵。
    private var rightTrigger = TriggerDetector()
    /// 右鍵扳機期間、最近 `TriggerDetector.window` 秒內的拇指距離與游標，點在拇指開始動之前的位置。
    private var triggerCursors: [(t: Double, distance: Double, cursor: Vec2)] = []
    /// 按住中的扳機：按下的時間、右鍵要點的位置（拇指開始動之前），以及縮放時上一格的游標高度。
    private var thumb: (t: Double, cursor: Vec2?, anchor: Double?)?
    /// 兩指捲動時的扳機 = ESC。
    private var escapeTrigger = TriggerDetector()
    /// 捲動中最近 `TapClicker.speedWindow` 秒的手掌中心，量 ESC 的手掌速度：捲動時 `clicker` 每幀重置，量不到。
    private var scrollPalms: [(t: Double, point: Vec2)] = []
    /// 上一幀輸出的游標。
    private var lastCursor: Vec2?
    /// 最後一次只有食指指向時輸出的游標。
    private var pointed: (cursor: Vec2, t: Double)?
    /// 捲動時游標停住的位置。
    private var held: Vec2?
    /// 最近一次兩指伸直時，食指尖減食指根部（正規化座標）。
    private var reach: Vec2?
    /// 分辨顫抖與移動，參數可調。
    public var stabilizer = PointerStabilizer()
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
        // 喚醒後只跟著操作者的手（`OperatorLock`）；狀態用上一幀的，這一幀喚醒時還是待命，取主要手。
        let hand = operatorLock.select(
            hands, width: width, height: height, palm: calibration.palmWidth, locked: machine.state != .idle
        )
        let geometry = hand.map { HandGeometry(hand: $0, width: width, height: height) }
        let measuredPalm = geometry?.palmWidth
        if let measuredPalm { lastPalm = (measuredPalm, t) }
        let palm = measuredPalm ?? lastPalm.flatMap { t - $0.t <= palmHold ? $0.width : nil }
        let sized = palm.map { palmRange.contains($0 / calibration.palmWidth) } ?? false
        let woke = wake.update(pose: sized ? geometry?.pose : .other, at: t)
        let tip = sized ? geometry?.normalized(.indexTip) : nil
        // 游標跟著食指 PIP 而不是指尖：按鍵式點擊只彎指尖兩節，PIP 移動只有指尖的約 1/3。
        let point = sized ? geometry?.normalized(.indexPIP) : nil
        let inside = point.map { isInside($0) } ?? false
        let pointing = inside && geometry?.isPointing(palmWidth: palm ?? 0) == true
        let knuckle = sized ? geometry?.normalized(.indexMCP) : nil
        let twoFingers = inside && !clicker.isPressed && geometry?.isPointing(palmWidth: palm ?? 0, fingers: 2) == true
        if twoFingers, let point, let knuckle { reach = Vec2(x: point.x - knuckle.x, y: point.y - knuckle.y) }
        // 捲動中彎手指時 PIP 會離開操作範圍，但手沒有離開：改用食指根部加上手指伸直時的 PIP 位移判斷。
        let placed = scroller.isScrolling ? knuckle.flatMap { k in reach.map { Vec2(x: k.x + $0.x, y: k.y + $0.y) } } : point
        let state = machine.update(
            woke: woke, pointing: pointing, visible: point != nil, inside: placed.map { isInside($0) } ?? false, at: t
        )
        var cursor: Vec2?
        if let point {
            if let last, t - last.t > resetGap {
                filter.reset()
                velocity = Vec2(x: 0, y: 0)
                self.last = nil
            }
            let steady = stabilizer.update(point, width: width, height: height, scale: calibration.palmWidth, at: t)
            let filtered = filter(map(steady), at: t)
            if let last, t > last.t {
                velocity.x += 0.5 * ((filtered.x - last.point.x) / (t - last.t) - velocity.x)
                velocity.y += 0.5 * ((filtered.y - last.point.y) / (t - last.t) - velocity.y)
            }
            last = (filtered, t)
            cursor = clamp(Vec2(x: filtered.x + velocity.x * lead, y: filtered.y + velocity.y * lead))
        }
        guard state == .active else {
            clicker = TapClicker()
            scroller = Scroller()
            held = nil
            thumb = nil
            return Output(state: state, cursor: nil)
        }
        // 食指尖比指根高出幾個掌寬：扳機與按鍵用來確認食指伸直，整隻手移動時不變。
        var rise: Double?
        if let tip, let palm, let knuckle {
            rise = (tip.y - knuckle.y) * Double(height) / palm
        }
        // 食指尖的高度（校準掌寬）：往上、往下甩就捲動，彎手指與抬手都算。
        let scroll = scroller.update(
            twoFingers: twoFingers, pointing: pointing, level: tip.map { $0.y * Double(height) / calibration.palmWidth }, at: t
        )
        // 扳機：拇指尖到食指 PIP。用沿用的掌寬：拇指壓下時常擋住食指根部。
        var distance: Double?
        if sized, let palm, let gap = geometry?.distance(.thumbTip, .indexPIP) { distance = gap / palm }
        let posed = [1, 2].contains { geometry?.isPointing(palmWidth: palm ?? 0, fingers: $0) == true }
        // 除以固定的校準掌寬：每幀量到的掌寬有約 5% 的雜訊，拿它換算位置，速度會多出約 0.7 掌寬／秒。
        let scale = calibration.palmWidth
        let palmPoint = sized ? geometry?.palmCenter.map { Vec2(x: $0.x / scale, y: $0.y / scale) } : nil
        if scroller.isScrolling {
            clicker = TapClicker()
            rightTrigger = TriggerDetector()
            triggerCursors = []
            thumb = nil
            if held == nil { held = pointed.flatMap { t - $0.t <= pointMemory ? $0.cursor : nil } ?? lastCursor }
            if let palmPoint { scrollPalms.append((t, palmPoint)) }
            scrollPalms.removeAll { t - $0.t > clicker.speedWindow }
            var palmSpeed: Double?
            if let first = scrollPalms.first, let last = scrollPalms.last, last.t > first.t {
                palmSpeed = first.point.distance(to: last.point) / (last.t - first.t)
            }
            // 同右鍵：手在動時（例如往上甩時抬手）拇指跟著晃不算，而且不留在按下狀態，才不會吃掉下一下。
            let triggered = escapeTrigger.update(distance: distance, rise: rise, posed: posed, at: t)
            let escape = triggered && sized && (palmSpeed ?? .infinity) < triggerStillSpeed
            if triggered, !escape { escapeTrigger = TriggerDetector() }
            return Output(
                state: state, cursor: held, scroll: scroll, escape: escape, scrolling: scroller.direction, rise: rise
            )
        }
        escapeTrigger = TriggerDetector()
        scrollPalms = []
        held = nil
        // 按鍵時食指會彎，食指尖只要仍高於指根就算指向姿勢。
        let tapPosed = geometry?.isPointing(palmWidth: palm ?? 0, up: 0.2) == true
        // 中指尖比中指根高出幾個掌寬：按鍵時中指不動。
        var middle: Double?
        if let palm, let tip = geometry?.normalized(.middleTip), let base = geometry?.normalized(.middleMCP) {
            middle = (tip.y - base.y) * Double(height) / palm
        }
        let click = clicker.update(
            cursor: cursor, flex: sized ? geometry?.indexFlex : nil, height: rise, middle: middle, posed: tapPosed, palm: palmPoint,
            valid: sized, at: t
        )
        // 右鍵：拇指壓下時食指也會動，點在最近 `window` 秒內拇指距離最大那一幀（開始動之前）的游標位置。
        let straight = posed && (rise ?? rightTrigger.straight) >= rightTrigger.straight
        if !straight {
            triggerCursors = []
        } else if let distance, let cursor {
            triggerCursors.append((t, distance, cursor))
        }
        triggerCursors.removeAll { t - $0.t > rightTrigger.window }
        let still = (clicker.palmSpeed ?? .infinity) < triggerStillSpeed
        let triggered = rightTrigger.update(distance: distance, rise: rise, posed: posed, at: t)
        let accepted = triggered && sized && still
        // 不算數的扳機（例如移動途中拇指跟著晃）不留在按下狀態：拇指平常若沒抬高，要等抬起 `lift` 才放開，會吃掉下一下。
        if triggered, !accepted { rightTrigger = TriggerDetector() }
        if accepted {
            let top = triggerCursors.map(\.distance).max()
            thumb = (t, triggerCursors.last(where: { $0.distance == top })?.cursor ?? click.cursor, nil)
            triggerCursors = []
        }
        // 放開時還沒到 `zoomDelay` 是右鍵；按住超過就是縮放：手每上下 `zoomStep` pt 縮放一格，放開不送右鍵。
        var rightClick = false
        var zoom: Int?
        var zooming = false
        var shown = click.cursor
        if let hold = thumb {
            shown = hold.cursor ?? shown
            if !rightTrigger.isPressed {
                rightClick = t - hold.t < zoomDelay
                thumb = nil
            } else if t - hold.t >= zoomDelay, let p = point {
                let y = (p.y - calibration.minY) / (calibration.maxY - calibration.minY) * screenHeight
                zooming = true
                let anchor = hold.anchor ?? y
                let steps = Int(((y - anchor) / zoomStep).rounded(.towardZero))
                if steps != 0 { zoom = steps }
                thumb?.anchor = anchor + Double(steps) * zoomStep
            }
        }
        lastCursor = shown
        if pointing, let shown { pointed = (shown, t) }
        return Output(
            state: state, cursor: shown, button: click.button, scroll: scroll, rightClick: rightClick, zoom: zoom, zooming: zooming,
            pressed: clicker.isPressed
        )
    }

    /// 快捷鍵、螢幕鎖定等外部原因停用：回到 Idle，須重新喚醒。
    public mutating func deactivate() {
        machine.reset()
    }

    /// 錄影重播用：略過喚醒，直接進入 Active。
    mutating func activate(at t: Double) {
        machine.activate(at: t)
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
