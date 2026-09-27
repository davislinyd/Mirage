import Foundation
import Testing
@testable import MirageCore

/// 掌心朝鏡頭、指尖朝上的合成右手（正規化座標）。`curled` 為 true 時四指指尖收回掌心；`pointing` 為 true 時
/// 只有食指伸直，食指尖在 (0.54, 0.52)。`offset` 平移整隻手。
private func makeHand(
    curled: Bool = false, pointing: Bool = false, thumbTip: Vec2 = Vec2(x: 0.62, y: 0.45), confidence: Double = 0.9,
    offset: Vec2 = Vec2(x: 0, y: 0)
) -> Hand {
    var joints = Array(repeating: JointSample(x: 0, y: 0, c: confidence), count: Joint.allCases.count)
    func set(_ joint: Joint, _ x: Double, _ y: Double) {
        joints[joint.rawValue] = JointSample(x: x + offset.x, y: y + offset.y, c: confidence)
    }
    set(.wrist, 0.5, 0.2)
    set(.thumbCMC, 0.56, 0.25)
    set(.thumbMCP, 0.6, 0.3)
    set(.thumbIP, 0.62, 0.36)
    set(.thumbTip, thumbTip.x, thumbTip.y)
    let fingers: [(mcp: Joint, pip: Joint, dip: Joint, tip: Joint, x: Double)] = [
        (.indexMCP, .indexPIP, .indexDIP, .indexTip, 0.54),
        (.middleMCP, .middlePIP, .middleDIP, .middleTip, 0.50),
        (.ringMCP, .ringPIP, .ringDIP, .ringTip, 0.46),
        (.littleMCP, .littlePIP, .littleDIP, .littleTip, 0.42),
    ]
    for finger in fingers {
        let bent = curled || (pointing && finger.tip != .indexTip)
        set(finger.mcp, finger.x, 0.35)
        set(finger.pip, finger.x, 0.42)
        set(finger.dip, finger.x, bent ? 0.38 : 0.47)
        set(finger.tip, finger.x, bent ? 0.33 : 0.52)
    }
    return Hand(chirality: .right, joints: joints)
}

@Suite struct OneEuroFilterTests {
    @Test func firstSamplePassesThrough() {
        var filter = OneEuroFilter()
        let output = filter(42, at: 0)
        #expect(output == 42)
    }

    @Test func suppressesTremorWhileStill() {
        var filter = OneEuroFilter()
        // 30 fps、±3 pt 的高頻抖動。
        let outputs = (0..<300).map { i in
            filter(100 + (i.isMultiple(of: 2) ? 3 : -3), at: Double(i) / 30)
        }
        #expect(outputs.suffix(150).allSatisfy { abs($0 - 100) < 1 })
    }

    @Test func fastMotionLagsLessThanPlainLowPass() {
        func lag(beta: Double) -> Double {
            var filter = OneEuroFilter(beta: beta)
            var output = 0.0
            // 1500 pt/s 的等速移動。
            for i in 0..<60 {
                output = filter(Double(i) * 50, at: Double(i) / 30)
            }
            return 59 * 50 - output
        }
        #expect(lag(beta: 0.007) < lag(beta: 0) / 3)
    }
}

@Suite struct PhaseTests {
    @Test func scheduleStartsAfterWarmup() {
        #expect(Phase.at(elapsed: 0)?.phase == .latency)
        #expect(Phase.at(elapsed: 32)?.phase == .still)
        #expect(Phase.at(elapsed: 32.5)?.remaining == 4.5)
        #expect(Phase.at(elapsed: Phase.totalDuration)?.phase == nil)
    }
}

@Suite struct HandGeometryTests {
    @Test func classifiesOpenHandAndFist() {
        #expect(HandGeometry(hand: makeHand(), width: 1000, height: 1000).pose == .open)
        #expect(HandGeometry(hand: makeHand(curled: true), width: 1000, height: 1000).pose == .fist)
    }

    @Test func pinchRatioIsScaleInvariant() throws {
        let open = try #require(HandGeometry(hand: makeHand(), width: 1000, height: 1000).pinchRatio)
        let scaled = try #require(HandGeometry(hand: makeHand(), width: 2000, height: 2000).pinchRatio)
        let pinched = try #require(HandGeometry(hand: makeHand(thumbTip: Vec2(x: 0.54, y: 0.52)), width: 1000, height: 1000).pinchRatio)
        #expect(open > 0.8)
        #expect(abs(open - scaled) < 1e-9)
        #expect(pinched == 0)
    }

    @Test func ignoresLowConfidenceJoints() {
        #expect(HandGeometry(hand: makeHand(confidence: 0.1), width: 1000, height: 1000).pinchRatio == nil)
    }

    @Test func detectsCurledIndexFinger() {
        #expect(HandGeometry(hand: makeHand(), width: 1000, height: 1000).indexCurled == false)
        #expect(HandGeometry(hand: makeHand(curled: true), width: 1000, height: 1000).indexCurled == true)
    }

    @Test func detectsPointingWithoutWrist() {
        func pointing(_ hand: Hand) -> Bool? {
            HandGeometry(hand: hand, width: 1280, height: 720).isPointing(palmWidth: 153.6)
        }
        var noWrist = makeHand(pointing: true)
        noWrist.joints[Joint.wrist.rawValue].c = 0.1
        #expect(pointing(makeHand(pointing: true)) == true)
        #expect(pointing(noWrist) == true)
        #expect(pointing(makeHand()) == false)
        #expect(pointing(makeHand(curled: true)) == false)
        var twoFingers = makeHand(pointing: true)
        twoFingers.joints[Joint.middleTip.rawValue].y = 0.52
        #expect(HandGeometry(hand: twoFingers, width: 1280, height: 720).isPointing(palmWidth: 153.6, fingers: 2) == true)
        #expect(pointing(twoFingers) == false)
    }
}

@Suite struct DetectorTests {
    @Test func pinchUsesHysteresis() {
        var detector = PinchDetector()
        var starts = 0
        for ratio in [0.9, 0.3, 0.2, 0.3, 0.35, nil, 0.2, 0.5, 0.2] as [Double?] where detector.update(ratio: ratio) {
            starts += 1
        }
        #expect(starts == 2)
    }

    @Test func clickConfirmsOnNextFrame() {
        func clicks(_ ratios: [Double?], valid: [Bool]? = nil) -> [Bool] {
            var detector = PinchClickDetector()
            return ratios.indices.map { detector.update(ratio: ratios[$0], valid: valid?[$0] ?? true) }
        }
        #expect(clicks([0.9, 0.2, 0.2, 0.2, 0.5]) == [false, false, true, false, false])
        #expect(clicks([0.9, 0.2, 0.5, 0.9]) == [false, false, false, false])
        #expect(clicks([0.9, 0.2, 0.2], valid: [true, false, true]) == [false, false, false])
        #expect(clicks([0.9, 0.2, 0.2], valid: [true, true, false]) == [false, false, false])
        #expect(clicks([0.9, 0.2, nil, 0.2]) == [false, false, false, false])
        #expect(clicks([nil, 0.2, 0.2, 0.9, 0.2, 0.2]) == [false, false, false, false, false, true])
    }

    /// 以 30 fps 依序送入各段姿勢，回傳觸發喚醒的幀序號。
    private func wakes(_ segments: [(pose: HandPose?, seconds: Double)]) -> [Int] {
        var detector = WakeDetector()
        var fired: [Int] = []
        var frame = 0
        for segment in segments {
            for _ in 0..<Int((segment.seconds * 30).rounded()) {
                if detector.update(pose: segment.pose, at: Double(frame) / 30) { fired.append(frame) }
                frame += 1
            }
        }
        return fired
    }

    @Test func wakeRequiresHeldOpenHandThenHeldFist() {
        #expect(wakes([(.open, 0.5), (.fist, 2)]) == [24])
        #expect(wakes([(.open, 0.5), (.fist, 0.5), (.open, 0.5), (.fist, 0.5)]) == [24, 54])
        #expect(wakes([(.open, 0.2), (.fist, 0.5)]) == [])
        #expect(wakes([(.open, 0.5), (.fist, 0.2), (.other, 0.3)]) == [])
        #expect(wakes([(.fist, 1)]) == [])
    }

    @Test func wakeToleratesSingleNoisyFrame() {
        #expect(wakes([(.open, 0.2), (.other, 1.0 / 30), (.open, 0.2), (nil, 1.0 / 30), (.fist, 0.5)]) == [23])
        #expect(wakes([(.open, 0.5), (.fist, 0.2), (.other, 1.0 / 30), (.fist, 0.2)]) == [24])
    }

    @Test func wakeToleratesTransitionPoses() {
        #expect(wakes([(.open, 0.5), (.other, 0.1), (.fist, 0.5)]) == [27])
        #expect(wakes([(.open, 0.5), (.other, 0.4), (.fist, 0.5)]) == [])
    }
}

@Suite struct GestureProbeTests {
    /// 靜止階段以 1280×720 建立掌寬基準，再以指定解析度送入張手、捏合、`confirm`（預設同樣是捏合）。
    /// 解析度減半時量到的掌寬只剩基準的一半，等同側手或離很遠的手。
    private func clicks(width: Int = 1280, height: Int = 720, confirm: Hand? = nil) -> Int {
        var probe = GestureProbe(mapper: ScreenMapper(screenWidth: 1440, screenHeight: 900))
        let still = (0..<30).map { i in
            FrameRecord(t: Double(i) / 30, phase: .still, width: 1280, height: 720, latencyMs: 0, inferenceMs: 0, hands: [makeHand()])
        }
        let pinched = makeHand(thumbTip: Vec2(x: 0.54, y: 0.52))
        let pinch = [makeHand(), pinched, confirm ?? pinched].enumerated().map { i, hand in
            FrameRecord(t: 1 + Double(i) / 30, phase: .pinch, width: width, height: height, latencyMs: 0, inferenceMs: 0, hands: [hand])
        }
        var clicks = 0
        for frame in still + pinch where probe.update(frame).clicked {
            clicks += 1
        }
        return clicks
    }

    @Test func clickRequiresHandNearBaselineSize() {
        #expect(clicks(width: 1280, height: 720) == 1)
        #expect(clicks(width: 640, height: 360) == 0)
    }

    @Test func reusesRecentPalmWidthWhileKnuckleIsHidden() {
        var hidden = makeHand(thumbTip: Vec2(x: 0.54, y: 0.52))
        hidden.joints[Joint.indexMCP.rawValue].c = 0.1
        #expect(clicks(confirm: hidden) == 1)
    }
}

@Suite struct CalibrationTests {
    /// 以 30 fps 送入食指尖每 2 秒繞 (0.5, 0.5) 一圈、半徑 `radius` 的手，回傳每幀的進度。
    private func progress(radius: Double, seconds: Double, pointing: Bool = true) -> [CalibrationSession.Progress] {
        var session = CalibrationSession()
        return (0..<Int((seconds * 30).rounded())).map { i in
            let t = Double(i) / 30
            let offset = Vec2(x: 0.5 + radius * cos(.pi * t) - 0.54, y: 0.5 + radius * sin(.pi * t) - 0.52)
            return session.update(hands: [makeHand(pointing: pointing, offset: offset)], width: 1280, height: 720, at: t)
        }
    }

    @Test func circleSetsPalmWidthAndRange() {
        guard case .done(let calibration)? = progress(radius: 0.15, seconds: 7.1).last else {
            Issue.record("校準沒有完成")
            return
        }
        #expect(abs(calibration.palmWidth - 153.6) < 1e-9)
        #expect(abs(calibration.minX - 0.35) < 0.01 && abs(calibration.maxX - 0.65) < 0.01)
        #expect(abs(calibration.minY - 0.35) < 0.01 && abs(calibration.maxY - 0.65) < 0.01)
    }

    @Test func smallCircleRestarts() {
        let results = progress(radius: 0.03, seconds: 7.5)
        let done = results.filter {
            if case .done = $0 { return true }
            return false
        }
        #expect(results.contains(.tooSmall))
        #expect(done.isEmpty)
    }

    @Test func onlyPointingHandCounts() {
        #expect(progress(radius: 0.15, seconds: 1, pointing: false).last == .collecting(remaining: 4, hint: .notPointing))
    }

    @Test func countsDownBeforeCollecting() {
        var session = CalibrationSession()
        #expect(session.update(hands: [], width: 1280, height: 720, at: 0) == .collecting(remaining: 4, hint: .noHand))
        guard case .countdown? = progress(radius: 0.15, seconds: 1).last,
              case .collecting(_, .pointing)? = progress(radius: 0.15, seconds: 4).last
        else {
            Issue.record("應先倒數 3 秒，再開始收集")
            return
        }
    }
}

@Suite struct ControlStateMachineTests {
    private enum Input { case wake, rest, point, outside, gone }

    /// 以 30 fps 依序送入各段輸入，回傳每段結束時的狀態。`.wake` 只在該段第一幀喚醒，之後同 `.rest`
    /// （手在操作範圍內但沒有指向）。
    private func states(_ segments: [(input: Input, seconds: Double)]) -> [ControlState] {
        var machine = ControlStateMachine()
        var frame = 0
        return segments.map { segment in
            for i in 0..<Int((segment.seconds * 30).rounded()) {
                let visible = segment.input != .gone
                _ = machine.update(
                    woke: segment.input == .wake && i == 0, pointing: segment.input == .point, visible: visible,
                    inside: visible && segment.input != .outside, at: Double(frame) / 30
                )
                frame += 1
            }
            return machine.state
        }
    }

    @Test func pointingAfterWakeActivates() {
        #expect(states([(.rest, 1), (.wake, 0.1), (.point, 0.3)]) == [.idle, .armed, .active])
        #expect(states([(.point, 2)]) == [.idle])
        #expect(states([(.wake, 0.1), (.point, 0.1), (.rest, 0.1), (.point, 0.1)]) == [.armed, .armed, .armed, .armed])
    }

    @Test func armedTimesOutUnlessWokenAgain() {
        #expect(states([(.wake, 0.1), (.rest, 3), (.point, 0.3)]) == [.armed, .idle, .idle])
        #expect(states([(.wake, 0.1), (.rest, 2), (.wake, 0.1), (.rest, 2), (.point, 0.3)]) == [.armed, .armed, .armed, .armed, .active])
    }

    @Test func activeEndsWhenHandLeaves() {
        #expect(states([(.wake, 0.1), (.point, 0.3), (.gone, 1.8), (.rest, 0.5)]) == [.armed, .active, .active, .active])
        #expect(states([(.wake, 0.1), (.point, 0.3), (.gone, 2.2)]).last == .idle)
        #expect(states([(.wake, 0.1), (.point, 0.3), (.outside, 0.8), (.rest, 0.5)]).last == .active)
        #expect(states([(.wake, 0.1), (.point, 0.3), (.outside, 1.2)]).last == .idle)
        #expect(states([(.wake, 0.1), (.point, 0.3), (.gone, 1.5), (.outside, 0.1)]).last == .idle)
    }
}

@Suite struct CursorControllerTests {
    private typealias Segment = (hand: Hand?, seconds: Double)

    /// 校準範圍為畫面中央 0.4–0.6、螢幕 1000×500 pt。以 30 fps 依序送入各段的手，回傳每一幀的輸出。
    private func outputs(_ segments: [Segment], width: Int = 1280, height: Int = 720) -> [CursorController.Output] {
        var controller = CursorController(
            calibration: Calibration(palmWidth: 153.6, minX: 0.4, minY: 0.4, maxX: 0.6, maxY: 0.6),
            screenWidth: 1000, screenHeight: 500
        )
        var outputs: [CursorController.Output] = []
        var frame = 0
        for segment in segments {
            for _ in 0..<Int((segment.seconds * 30).rounded()) {
                let hands = segment.hand.map { [$0] } ?? []
                outputs.append(controller.update(hands: hands, width: width, height: height, at: Double(frame) / 30))
                frame += 1
            }
        }
        return outputs
    }

    /// 同 `outputs`，只回傳最後一幀。
    private func run(_ segments: [Segment], width: Int = 1280, height: Int = 720) -> CursorController.Output? {
        outputs(segments, width: width, height: height).last
    }

    /// 先做喚醒手勢（張手 → 握拳），再接 `rest`。
    private func woken(_ rest: Segment...) -> [Segment] {
        let wake: [Segment] = [(makeHand(), 0.5), (makeHand(curled: true), 0.5)]
        return wake + rest
    }

    /// 食指指向、食指尖在 (`x`, `y`) 的手；`pinched` 為 true 時拇指尖碰到食指尖，`twoFingers` 為 true 時中指也伸直。
    private func pointing(_ x: Double, _ y: Double, pinched: Bool = false, twoFingers: Bool = false) -> Hand {
        var hand = makeHand(
            pointing: true, thumbTip: pinched ? Vec2(x: 0.54, y: 0.52) : Vec2(x: 0.62, y: 0.45), offset: Vec2(x: x - 0.54, y: y - 0.52)
        )
        if twoFingers {
            hand.joints[Joint.middleDIP.rawValue].y += 0.09
            hand.joints[Joint.middleTip.rawValue].y += 0.19
        }
        return hand
    }

    @Test func pointingAfterWakeMovesCursor() throws {
        // 食指尖在校準範圍左上 1/4 處，鏡像後游標在螢幕右上 1/4 處。
        let output = try #require(run(woken((pointing(0.45, 0.55), 2))))
        let cursor = try #require(output.cursor)
        #expect(output.state == .active)
        #expect(abs(cursor.x - 750) < 1 && abs(cursor.y - 375) < 1)
    }

    @Test func cursorStopsAtScreenEdge() throws {
        let cursor = try #require(run(woken((pointing(0.35, 0.32), 2)))?.cursor)
        #expect(cursor.x <= 1000 && cursor.x > 999)
        #expect(cursor.y >= 0 && cursor.y < 1)
    }

    @Test func pointingWithoutWakeDoesNothing() throws {
        let output = try #require(run([(pointing(0.5, 0.5), 3)]))
        #expect(output.state == .idle)
        #expect(output.cursor == nil)
    }

    @Test func handFarFromCalibratedSizeCannotWake() throws {
        // 解析度減半時掌寬只剩校準值的一半，等同離鏡頭很遠的手，例如背後的旁人。
        let output = try #require(run(woken((pointing(0.5, 0.5), 1)), width: 640, height: 360))
        #expect(output.state == .idle)
    }

    /// 食指尖在 (`x`, `y`) 時彎起四指的手（食指尖比指根低約 0.09 掌寬）；`pinched` 為 true 時拇指尖貼著彎起的食指尖。
    private func bent(_ x: Double, _ y: Double, pinched: Bool = false) -> Hand {
        makeHand(curled: true, thumbTip: pinched ? Vec2(x: 0.54, y: 0.33) : Vec2(x: 0.62, y: 0.45), offset: Vec2(x: x - 0.54, y: y - 0.52))
    }

    @Test func twoFingersScrollWhileCursorHolds() throws {
        // 指著 (0.5, 0.5) 後伸直中指，兩指彎下再伸直。食指尖高度從 0.80 掌寬降到 −0.09。
        let scrolling = outputs(woken(
            (pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, twoFingers: true), 0.3), (bent(0.5, 0.5), 0.3),
            (pointing(0.5, 0.5, twoFingers: true), 0.3)
        )).filter { $0.scroll != nil }
        let first = try #require(scrolling.first)
        let cursor = try #require(first.cursor)
        // 彎下時捲動 0.89 × 200 pt，內容往下；之後是慣性，伸直回來不往回捲。
        #expect(abs((first.scroll ?? 0) + 178) < 1.5)
        #expect(scrolling.allSatisfy { ($0.scroll ?? 0) < 0 && $0.scrolling == .bend })
        #expect(abs(cursor.x - 500) < 1 && abs(cursor.y - 250) < 1)
        #expect(scrolling.allSatisfy { $0.cursor == cursor && $0.button == nil })
    }

    @Test func pinchWhileScrollingRightClicks() {
        let frames = outputs(woken(
            (pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, twoFingers: true), 0.3),
            (pointing(0.5, 0.5, pinched: true, twoFingers: true), 0.2), (pointing(0.5, 0.5, twoFingers: true), 0.3)
        ))
        #expect(frames.filter(\.rightClick).count == 1)
        #expect(frames.allSatisfy { $0.button == nil })
    }

    @Test func fistWhileScrollingDoesNotRightClick() {
        // 彎成拳頭時拇指貼著食指，比例和捏合一樣小，但食指是彎的。
        let frames = outputs(woken(
            (pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, twoFingers: true), 0.3), (bent(0.5, 0.5, pinched: true), 0.3),
            (pointing(0.5, 0.5, twoFingers: true), 0.3)
        ))
        #expect(frames.contains { $0.scroll != nil })
        #expect(frames.allSatisfy { !$0.rightClick && $0.button == nil })
    }

    @Test func bentFingersBelowRangeStayActive() throws {
        // 在操作範圍下緣附近彎著停 1.5 秒：指尖低於操作範圍，但手沒有移動。
        let output = try #require(run(woken(
            (pointing(0.5, 0.42), 1), (pointing(0.5, 0.42, twoFingers: true), 0.3), (bent(0.5, 0.42), 1.5)
        )))
        #expect(output.state == .active)
        #expect(output.scrolling == .straighten)
    }

    @Test func pinchClicksOnlyWhileActive() {
        let pinch: [Segment] = [(pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, pinched: true), 0.2), (pointing(0.5, 0.5), 0.5)]
        #expect(outputs(woken() + pinch).compactMap(\.button) == [.down, .up])
        #expect(outputs(pinch).allSatisfy { $0.button == nil })
    }

    @Test func losingHandDeactivates() throws {
        let short = try #require(run(woken((pointing(0.5, 0.5), 1), (nil, 1.5), (pointing(0.5, 0.5), 1))))
        let long = try #require(run(woken((pointing(0.5, 0.5), 1), (nil, 2.2), (pointing(0.5, 0.5), 1))))
        #expect(short.state == .active)
        #expect(long.state == .idle)
        #expect(long.cursor == nil)
    }
}

@Suite struct PinchClickerTests {
    /// 食指對應的游標 (`x`, `y`) 與捏合比例；nil 表示看不到手。
    private typealias Frame = (x: Double, y: Double, ratio: Double)?

    /// 手不動，食指指著 (500, 300) 半秒。
    private let pointing = [Frame](repeating: (500, 300, 1), count: 15)

    /// 以 30 fps 依序送入各幀，食指根部每幀移動 `anchorStep`（正規化影像座標），回傳每一幀的輸出。
    private func run(_ frames: [Frame], anchorStep: Double = 0) -> [PinchClicker.Output] {
        var clicker = PinchClicker()
        return frames.enumerated().map { i, frame in
            clicker.update(
                cursor: frame.map { Vec2(x: $0.x, y: $0.y) }, ratio: frame?.ratio,
                anchor: frame.map { _ in Vec2(x: 0.5 + anchorStep * Double(i), y: 0.5) }, valid: true, at: Double(i) / 30
            )
        }
    }

    @Test func clickLandsWhereFingerPointedBeforePinch() {
        // 捏合時食指尖往下帶著游標偏移，放開時再回來。
        let outputs = run(pointing + [(500, 200, 0.7), (500, 150, 0.4), (500, 120, 0.2), (500, 100, 0.15), (500, 150, 0.5), (500, 250, 0.8)])
        #expect(outputs.compactMap(\.button) == [.down, .up])
        #expect(outputs.dropFirst(15).allSatisfy { $0.cursor == Vec2(x: 500, y: 300) })
    }

    @Test func holdingPinchDrags() {
        // 捏住 0.6 秒後手往右移 100 pt，放開途中的移動不算。
        let hold = [Frame](repeating: (500, 100, 0.15), count: 18)
        let outputs = run(pointing + [(500, 200, 0.7), (500, 100, 0.2)] + hold + [(550, 100, 0.15), (600, 100, 0.15), (650, 150, 0.4), (600, 250, 0.8)])
        #expect(outputs.compactMap(\.button) == [.down, .up])
        #expect(outputs.last?.cursor == Vec2(x: 600, y: 300))
    }

    @Test func movingHandDoesNotFreeze() {
        // 手快速移動時比例掉了三成（例如動態模糊），不是捏合。
        let frames: [Frame] = (0..<20).map { i in (Double(i) * 50, 300, i == 15 ? 0.7 : 1) }
        let outputs = run(frames, anchorStep: 0.05)
        #expect(outputs.map(\.cursor) == frames.map { $0.map { Vec2(x: $0.x, y: $0.y) } })
        #expect(outputs.allSatisfy { $0.button == nil })
    }

    @Test func releasesWhenHandIsLost() {
        let outputs = run(pointing + [(500, 200, 0.7), (500, 100, 0.2), (500, 100, 0.15)] + [Frame](repeating: nil, count: 12))
        #expect(outputs.compactMap(\.button) == [.down, .up])
    }
}

@Suite struct ScrollerTests {
    private typealias Frame = (scroll: Double, scrolling: Bool, stroke: Scroller.Stroke)

    /// 以 30 fps 依序送入各段：伸直幾指（2 = 食指與中指，1 = 只有食指，0 = 彎著）、秒數、食指尖高度每秒的變化（掌寬）。
    /// 高度從伸直的 0.9 開始。回傳每一幀的捲動距離，與送入後是否在兩指捲動中、會捲動的那一下。
    private func run(_ segments: [(fingers: Int, seconds: Double, speed: Double)]) -> [Frame] {
        var scroller = Scroller()
        var frames: [Frame] = []
        var height = 0.9
        for segment in segments {
            for _ in 0..<Int((segment.seconds * 30).rounded()) {
                height += segment.speed / 30
                let scroll = scroller.update(
                    twoFingers: segment.fingers == 2, pointing: segment.fingers == 1, height: height, at: Double(frames.count) / 30
                )
                frames.append((scroll ?? 0, scroller.isScrolling, scroller.stroke))
            }
        }
        return frames
    }

    private func total(_ frames: some Sequence<Frame>) -> Double {
        frames.reduce(0) { $0 + $1.scroll }
    }

    @Test func bendScrollsAndStraighteningDoesNot() {
        // 慢慢彎到 0.06 再伸直，沒有慣性；最後收回中指。
        let frames = run([(2, 0.2, 0), (0, 0.7, -1.2), (0, 0.1, 0), (0, 0.7, 1.2), (2, 0.3, 0), (1, 0.3, 0)])
        #expect(abs(total(frames) + 168) < 2)
        #expect(frames.dropFirst(27).allSatisfy { $0.scroll == 0 })
        #expect(frames.allSatisfy { $0.stroke == .bend })
        #expect(frames.suffix(3).allSatisfy { !$0.scrolling })
    }

    @Test func restingBentSwitchesToStraightening() {
        // 彎著停超過 1 秒後，伸直那一下捲動、內容往上，再彎下不捲。
        let frames = run([(2, 0.2, 0), (0, 0.7, -1.2), (0, 1.2, 0), (0, 0.7, 1.2), (0, 0.7, -1.2)])
        #expect(abs(total(frames.prefix(27)) + 168) < 2)
        #expect(frames[62].stroke == .straighten)
        #expect(abs(total(frames.dropFirst(63).prefix(21)) - 168) < 2)
        #expect(frames.suffix(21).allSatisfy { $0.scroll == 0 && $0.stroke == .straighten })
    }

    @Test func flickKeepsScrolling() {
        // 0.1 秒彎下 1.2 掌寬：停住後繼續捲動並減速，伸直回來時也不中斷，最後停止。
        let frames = run([(2, 0.2, 0), (0, 0.1, -12), (0, 0.3, 0), (0, 0.1, 12), (2, 2.5, 0)])
        #expect(abs(total(frames.prefix(9)) + 240) < 2)
        #expect(total(frames.dropFirst(9)) < -400)
        #expect(frames.dropFirst(9).prefix(15).allSatisfy { $0.scroll < 0 && $0.scrolling })
        #expect(frames.suffix(10).allSatisfy { $0.scroll == 0 })
    }

    @Test func pinchDipDoesNotScroll() {
        // 兩指伸直時捏合，食指尖降到 0.3 掌寬再回來。
        let frames = run([(2, 0.2, 0), (0, 0.1, -6), (0, 0.1, 6), (2, 0.3, 0)])
        #expect(frames.allSatisfy { $0.scroll == 0 })
        #expect(frames.dropFirst(3).allSatisfy { $0.scrolling })
    }

    @Test func briefTwoFingersDoNotScroll() {
        let frames = run([(1, 0.2, 0), (2, 2.0 / 30, 0), (0, 0.2, -3)])
        #expect(frames.allSatisfy { $0.scroll == 0 && !$0.scrolling })
    }
}

@Suite struct ScreenMapperTests {
    let mapper = ScreenMapper(screenWidth: 1000, screenHeight: 500)

    @Test func mirrorsAndScalesBox() {
        #expect(mapper.map(Vec2(x: 0.5, y: 0.5)) == Vec2(x: 500, y: 250))
        #expect(mapper.map(Vec2(x: 0.25, y: 0.75)) == Vec2(x: 1000, y: 500))
    }

    @Test func mirroredNormalizedInvertsMapping() {
        let back = mapper.mirroredNormalized(fromScreen: mapper.map(Vec2(x: 0.3, y: 0.6)))
        #expect(abs(back.x - 0.7) < 1e-9)
        #expect(abs(back.y - 0.6) < 1e-9)
    }
}

@Suite struct SpikeAnalysisTests {
    @Test func estimatesFilterLag() throws {
        let raw = (0..<120).map { Vec2(x: 300 * sin(Double($0) * 0.1), y: 0) }
        let delayed = raw.indices.map { raw[max(0, $0 - 3)] }
        let lag = try #require(SpikeAnalysis.lagMs(raw: raw, filtered: delayed, interval: 1.0 / 30))
        #expect(abs(lag - 100) < 10)
    }

    @Test func stillPhaseReportsLowerFilteredJitter() throws {
        let frames = (0..<150).map { i in
            var hand = makeHand()
            hand.joints[Joint.indexTip.rawValue].x += i.isMultiple(of: 2) ? 0.004 : -0.004
            return FrameRecord(t: 3 + Double(i) / 30, phase: .still, width: 1280, height: 720, latencyMs: 40, inferenceMs: 8, hands: [hand])
        }
        let report = try #require(SpikeAnalysis.report(frames: frames, mapper: ScreenMapper(screenWidth: 1440, screenHeight: 900)).first)
        let raw = try #require(report.jitterRaw)
        let filtered = try #require(report.jitterFiltered)
        #expect(report.detectionRate == 1)
        #expect(filtered.p95 < raw.p95 / 3)
    }

    @Test func latencyPhaseIsReportedPerConfigAfterSettling() {
        var frames: [FrameRecord] = []
        for (index, config) in ["A", "B"].enumerated() {
            for i in 0..<120 {
                frames.append(FrameRecord(
                    t: Double(index * 120 + i) / 30, phase: .latency, width: 1280, height: 720,
                    latencyMs: config == "A" ? 100 : 60, inferenceMs: 20, hands: [makeHand()], config: config,
                    deliveryMs: config == "A" ? 80 : 40
                ))
            }
        }
        let reports = SpikeAnalysis.report(frames: frames, mapper: ScreenMapper(screenWidth: 1440, screenHeight: 900))
        #expect(reports.compactMap(\.config) == ["A", "B"])
        #expect(reports.map(\.frames) == [60, 60])
        #expect(reports.map(\.latencyP50) == [100, 60])
        #expect(reports.map(\.deliveryP50) == [80, 40])
    }
}
