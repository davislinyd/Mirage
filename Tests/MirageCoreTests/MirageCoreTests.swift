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

/// 張手後五指尖收攏到 (0.5, 0.49) 附近的手。
private func makeGatheredHand() -> Hand {
    var hand = makeHand()
    for (joint, x) in [(Joint.thumbTip, 0.51), (.indexTip, 0.505), (.middleTip, 0.5), (.ringTip, 0.495), (.littleTip, 0.49)] {
        hand.joints[joint.rawValue].x = x
        hand.joints[joint.rawValue].y = 0.49
    }
    return hand
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
        let lead = Script.reading + Script.countdown
        #expect(Script.m0.at(elapsed: 0)?.phase == .latency)
        #expect(Script.m0.at(elapsed: lead + 32)?.phase == .still)
        #expect(Script.m0.at(elapsed: 2 * lead + 32.5)?.remaining == 4.5)
        #expect(Script.m0.at(elapsed: Script.m0.totalDuration)?.phase == nil)
        #expect(Script.gestures.at(elapsed: 0)?.phase == .move)
    }

    @Test func desktopScriptIsRegisteredAndRecordsEachDirection() {
        #expect(Script.all.contains { $0.name == "desktop" })
        #expect(Script.desktop.at(elapsed: 0)?.phase == .move)
        for phase in [Phase.desktopRight, .desktopLeft, .desktopUp, .desktopDown, .desktopHold] {
            #expect(Script.desktop.phases.contains(phase) && phase.duration > 0 && !phase.instruction.isEmpty)
        }
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

    @Test func measuresGatheredFingertips() throws {
        func measure(_ hand: Hand) throws -> (spread: Double, rise: Double) {
            let geometry = HandGeometry(hand: hand, width: 1000, height: 1000)
            return (try #require(geometry.tipSpread), try #require(geometry.tipRise))
        }
        #expect(try measure(makeHand()).spread > 0.8)
        let gathered = try measure(makeGatheredHand())
        #expect(gathered.spread < 0.2 && gathered.rise > 1)
        #expect(try #require(HandGeometry(hand: makeGatheredHand(), width: 1000, height: 1000).thumbLift) > 1)
        #expect(try measure(makeHand(curled: true)).rise < 0)
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

    private typealias Gesture = (pose: HandPose?, spread: Double?, rise: Double?, thumb: Double?, lift: Double?)
    private let open: Gesture = (.open, 1.0, 1.0, 1.5, 0.5)
    private let gathered: Gesture = (.open, 0.1, 0.5, 0.1, 0.4)
    /// 照平常速度捏合：指尖降到指根高度，`pose` 判成握拳。
    private let loweredGather: Gesture = (.fist, 0.4, -0.1, 0.1, 0.2)
    /// 握拳時指尖也收得很攏，但收到指根下方，拇指壓在食指上。
    private let fist: Gesture = (.fist, 0.4, -0.4, 0.4, 0.0)
    /// 手舉高時的握拳：指尖高度與拇指位置都像捏合，只有拇指是橫的。
    private let flatThumbFist: Gesture = (.fist, 0.4, -0.2, 0.2, 0.0)
    private let point: Gesture = (.other, 0.9, 0.3, 1.0, 0.5)

    /// 以 30 fps 依序送入各段量測，回傳觸發五指捏合的幀序號。
    private func gathers(_ segments: [(gesture: Gesture, seconds: Double)]) -> [Int] {
        var detector = GatherDetector()
        var fired: [Int] = []
        var frame = 0
        for segment in segments {
            for _ in 0..<Int((segment.seconds * 30).rounded()) {
                let g = segment.gesture
                if detector.update(pose: g.pose, spread: g.spread, rise: g.rise, thumb: g.thumb, thumbLift: g.lift, at: Double(frame) / 30) {
                    fired.append(frame)
                }
                frame += 1
            }
        }
        return fired
    }

    @Test func gatherRequiresHeldOpenHandFirst() {
        #expect(gathers([(open, 0.5), (gathered, 1)]) == [17])
        #expect(gathers([(open, 0.5), (gathered, 0.5), (open, 0.5), (gathered, 0.5)]) == [17, 47])
        #expect(gathers([(open, 0.1), (gathered, 0.5)]) == [])
        #expect(gathers([(point, 0.5), (gathered, 0.5)]) == [])
        #expect(gathers([(open, 0.5), (point, 0.8), (gathered, 0.5)]) == [])
        #expect(gathers([(open, 0.5), (loweredGather, 1)]) == [17])
    }

    @Test func fistIsNotGather() {
        #expect(gathers([(open, 0.5), (fist, 1)]) == [])
        #expect(gathers([(open, 0.5), (flatThumbFist, 1)]) == [])
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
    /// 以 30 fps 送入食指尖每 2 秒繞 (0.5, 0.5) 一圈、半徑 `radius` 的手，回傳每幀的進度。食指 PIP 在指尖下方 0.1，
    /// 繞 (0.5, 0.4)。
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
        #expect(abs(calibration.minY - 0.25) < 0.01 && abs(calibration.maxY - 0.55) < 0.01)
        #expect(calibration.version == Calibration.currentVersion)
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

    /// 食指指向、食指尖在 (`x`, `y`) 的手，游標跟著的 PIP 在指尖下方 0.1；`pressed` 為 true 時拇指壓在食指第二關節旁
    /// （扳機，距離約 0.21 掌寬，平常約 0.68），`tapped` 為 true 時指尖兩節往下彎約 35°（按鍵），`twoFingers` 為
    /// true 時中指也伸直，`threeFingers` 為 true 時中指與無名指都伸直。
    private func pointing(
        _ x: Double, _ y: Double, pressed: Bool = false, tapped: Bool = false, twoFingers: Bool = false, threeFingers: Bool = false
    ) -> Hand {
        var hand = makeHand(
            pointing: true, thumbTip: pressed ? Vec2(x: 0.565, y: 0.42) : Vec2(x: 0.62, y: 0.45), offset: Vec2(x: x - 0.54, y: y - 0.52)
        )
        if tapped {
            hand.joints[Joint.indexDIP.rawValue].x += 0.01
            hand.joints[Joint.indexDIP.rawValue].y -= 0.005
            hand.joints[Joint.indexTip.rawValue].x += 0.02
            hand.joints[Joint.indexTip.rawValue].y -= 0.03
        }
        if twoFingers || threeFingers {
            hand.joints[Joint.middleDIP.rawValue].y += 0.09
            hand.joints[Joint.middleTip.rawValue].y += 0.19
        }
        if threeFingers {
            hand.joints[Joint.ringDIP.rawValue].y += 0.09
            hand.joints[Joint.ringTip.rawValue].y += 0.19
        }
        return hand
    }

    @Test func pointingAfterWakeMovesCursor() throws {
        // 食指 PIP 在校準範圍左上 1/4 處，鏡像後游標在螢幕右上 1/4 處。
        let output = try #require(run(woken((pointing(0.45, 0.65), 2))))
        let cursor = try #require(output.cursor)
        #expect(output.state == .active)
        #expect(abs(cursor.x - 750) < 1 && abs(cursor.y - 375) < 1)
    }

    @Test func cursorStopsAtScreenEdge() throws {
        let cursor = try #require(run(woken((pointing(0.35, 0.42), 2)))?.cursor)
        #expect(cursor.x <= 1000 && cursor.x > 999)
        #expect(cursor.y >= 0 && cursor.y < 1)
    }

    @Test func pointingWithoutWakeDoesNothing() throws {
        let output = try #require(run([(pointing(0.5, 0.5), 3)]))
        #expect(output.state == .idle)
        #expect(output.cursor == nil)
    }

    @Test func gatherWhileActiveMinimizes() {
        let frames = outputs(woken((pointing(0.5, 0.5), 1), (makeHand(), 0.5), (makeGatheredHand(), 0.5)))
        #expect(frames.filter(\.minimize).count == 1)
        #expect(outputs([(makeHand(), 0.5), (makeGatheredHand(), 0.5)]).allSatisfy { !$0.minimize })
    }

    @Test func handFarFromCalibratedSizeCannotWake() throws {
        // 解析度減半時掌寬只剩校準值的一半，等同離鏡頭很遠的手，例如背後的旁人。
        let output = try #require(run(woken((pointing(0.5, 0.5), 1)), width: 640, height: 360))
        #expect(output.state == .idle)
    }

    /// 食指尖在 (`x`, `y`) 時彎起四指的手（食指尖比指根低約 0.09 掌寬）；`pressed` 為 true 時拇指壓在食指第二關節旁。
    private func bent(_ x: Double, _ y: Double, pressed: Bool = false) -> Hand {
        makeHand(curled: true, thumbTip: pressed ? Vec2(x: 0.565, y: 0.42) : Vec2(x: 0.62, y: 0.45), offset: Vec2(x: x - 0.54, y: y - 0.52))
    }

    @Test func twoFingersScrollWhileCursorHolds() throws {
        // PIP 指著 (0.5, 0.5) 後伸直中指，兩指彎下再伸直。食指尖高度從 0.80 掌寬降到 −0.09。
        let scrolling = outputs(woken(
            (pointing(0.5, 0.6), 1), (pointing(0.5, 0.6, twoFingers: true), 0.3), (bent(0.5, 0.6), 0.3),
            (pointing(0.5, 0.6, twoFingers: true), 0.3)
        )).filter { $0.scroll != nil }
        let first = try #require(scrolling.first)
        let cursor = try #require(first.cursor)
        // 彎下是往下甩（一幀內 0.89 掌寬，每秒 13.35 掌寬）：以 13.35 ÷ 往下門檻 8 × 1200 = 每秒約 2000 pt 開始捲、
        // 逐漸減速，內容往下；伸直回來不往回捲。
        #expect(abs((first.scroll ?? 0) + 62) < 2)
        #expect(scrolling.allSatisfy { ($0.scroll ?? 0) < 0 && $0.scrolling == .down })
        // 防抖在中速移動後可能留下幾 pt 的偏差，下次快速移動才收回。
        #expect(abs(cursor.x - 500) < 5 && abs(cursor.y - 250) < 5)
        #expect(scrolling.allSatisfy { $0.cursor == cursor && $0.button == nil })
    }

    @Test func raisingHandQuicklyScrollsContentUp() {
        // 兩指伸直後，手很快往上抬 0.1（指尖一幀內高 0.47 掌寬）：往上甩，內容往上。
        let scrolling = outputs(woken(
            (pointing(0.5, 0.6), 1), (pointing(0.5, 0.6, twoFingers: true), 0.3), (pointing(0.5, 0.7, twoFingers: true), 0.3)
        )).filter { $0.scroll != nil }
        #expect(!scrolling.isEmpty && scrolling.allSatisfy { ($0.scroll ?? 0) > 0 && $0.scrolling == .up })
    }

    @Test func triggerWhileScrollingPressesEscape() {
        let frames = outputs(woken(
            (pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, twoFingers: true), 0.3),
            (pointing(0.5, 0.5, pressed: true, twoFingers: true), 0.2), (pointing(0.5, 0.5, twoFingers: true), 0.3)
        ))
        #expect(frames.filter(\.escape).count == 1)
        #expect(frames.allSatisfy { !$0.rightClick && $0.button == nil })
    }

    @Test func triggerWhileRaisingHandDoesNotPressEscape() {
        // 兩指時手往上抬（手掌每秒約 1.4 掌寬），拇指跟著晃到食指旁：同右鍵，手在動時不算。
        let rising: [Segment] = (0..<8).map { i in (pointing(0.5, 0.5 + 0.01 * Double(i), pressed: i >= 3, twoFingers: true), 1.0 / 30) }
        let frames = outputs(
            woken((pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, twoFingers: true), 0.3)) + rising
                + [(pointing(0.5, 0.57, twoFingers: true), 0.3)]
        )
        #expect(frames.contains { $0.scrolling != nil })
        #expect(frames.allSatisfy { !$0.escape && !$0.rightClick })
    }

    @Test func fistWhileScrollingDoesNotRightClick() {
        // 彎成拳頭時拇指貼著食指，距離和扳機一樣近，但食指是彎的。
        let frames = outputs(woken(
            (pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, twoFingers: true), 0.3), (bent(0.5, 0.5, pressed: true), 0.3),
            (pointing(0.5, 0.5, twoFingers: true), 0.3)
        ))
        #expect(frames.contains { $0.scroll != nil })
        #expect(frames.allSatisfy { !$0.rightClick && !$0.escape && $0.button == nil })
    }

    @Test func bentFingersBelowRangeStayActive() throws {
        // 在操作範圍下緣附近彎著停 1.5 秒：指尖低於操作範圍，但手沒有移動。
        let output = try #require(run(woken(
            (pointing(0.5, 0.42), 1), (pointing(0.5, 0.42, twoFingers: true), 0.3), (bent(0.5, 0.42), 1.5)
        )))
        #expect(output.state == .active)
        #expect(output.scrolling == .down)
    }

    @Test func tapClicksOnlyWhileActive() {
        let tap: [Segment] = [(pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, tapped: true), 0.2), (pointing(0.5, 0.5), 0.5)]
        #expect(outputs(woken() + tap).compactMap(\.button) == [.down, .up])
        #expect(outputs(tap).allSatisfy { $0.button == nil })
    }

    @Test func thumbTriggerRightClicksOnRelease() throws {
        let trigger: [Segment] = [(pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, pressed: true), 0.2), (pointing(0.5, 0.5), 0.5)]
        let frames = outputs(woken() + trigger)
        #expect(frames.filter(\.rightClick).count == 1)
        // 拇指抬起才送出：按住超過 `zoomDelay` 會變成縮放。
        let released = 30 + 30 + 6
        #expect(try #require(frames.firstIndex { $0.rightClick }) >= released)
        #expect(frames.allSatisfy { $0.button == nil && !$0.escape && $0.zoom == nil && !$0.zooming })
    }

    @Test func holdingTriggerZoomsWithHandHeight() {
        func hold(to y: Double) -> [CursorController.Output] {
            let raise: [Segment] = (1...15).map { i in (pointing(0.5, 0.5 + (y - 0.5) * Double(i) / 15, pressed: true), 1.0 / 30) }
            return outputs(woken((pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, pressed: true), 0.6)) + raise + [(pointing(0.5, y), 0.5)])
        }
        let up = hold(to: 0.62)
        #expect(up.contains { $0.zooming })
        #expect(up.compactMap(\.zoom).reduce(0, +) >= 1)
        #expect(up.compactMap(\.zoom).allSatisfy { $0 > 0 })
        #expect(!up.contains { $0.rightClick })
        // 縮放時游標停在按下前的位置。
        let zooming = up.filter(\.zooming)
        #expect(zooming.allSatisfy { $0.cursor == zooming.first?.cursor })
        let down = hold(to: 0.38)
        #expect(down.compactMap(\.zoom).reduce(0, +) <= -1)
        #expect(!down.contains { $0.rightClick })
    }

    @Test func holdingTriggerStillDoesNothing() {
        let frames = outputs(woken((pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, pressed: true), 0.8), (pointing(0.5, 0.5), 0.5)))
        #expect(frames.contains { $0.zooming })
        #expect(!frames.contains { $0.rightClick || $0.zoom != nil })
    }

    @Test func triggerWhileMovingDoesNotBlockNextRightClick() {
        // 食指尖在 (`x`, 0.5)，拇指尖到食指 PIP 約 `thumb` 掌寬。
        func hand(_ x: Double, thumb: Double) -> Hand {
            makeHand(pointing: true, thumbTip: Vec2(x: 0.54 + thumb * 0.12, y: 0.42), offset: Vec2(x: x - 0.54, y: -0.02))
        }
        // 快速移到目標途中拇指跟著壓下（手在動，不算右鍵）；之後拇指只抬到 0.29，沒有明顯抬起。
        let moving: [Segment] = (0..<13).map { i in (hand(0.45 + Double(i) * 0.01, thumb: i < 4 ? 0.68 : 0.21), 1.0 / 30) }
        let frames = outputs(woken((hand(0.45, thumb: 0.68), 1)) + moving + [
            (hand(0.57, thumb: 0.29), 0.6), (hand(0.57, thumb: 0.1), 0.3), (hand(0.57, thumb: 0.29), 0.5),
        ])
        let clicks = frames.indices.filter { frames[$0].rightClick }
        #expect(clicks.count == 1)
        #expect(clicks.allSatisfy { $0 > frames.count - 25 })
    }

    @Test func bystanderHandDoesNotTakeOver() {
        // 喚醒並指向後，畫面另一邊出現旁人的手（右手、信心更高、一直在動），輸出要和沒有旁人時完全相同。
        func bystander(_ i: Int) -> Hand {
            var hand = makeHand(pointing: true, confidence: 0.99, offset: Vec2(x: 0.3 + Double(i % 10) * 0.005, y: 0))
            hand.chirality = .right
            return hand
        }
        let moving: [Segment] = (0..<60).map { i in (pointing(0.45 + Double(i) * 0.002, 0.5), 1.0 / 30) }
        let alone = outputs(woken((pointing(0.45, 0.5), 1)) + moving)
        var controller = CursorController(
            calibration: Calibration(palmWidth: 153.6, minX: 0.4, minY: 0.4, maxX: 0.6, maxY: 0.6), screenWidth: 1000, screenHeight: 500
        )
        var frame = 0
        var crowded: [CursorController.Output] = []
        for segment in woken((pointing(0.45, 0.5), 1)) + moving {
            for _ in 0..<Int((segment.seconds * 30).rounded()) {
                var hands = segment.hand.map { [$0] } ?? []
                if frame >= 45 { hands.append(bystander(frame)) }
                crowded.append(controller.update(hands: hands, width: 1280, height: 720, at: Double(frame) / 30))
                frame += 1
            }
        }
        #expect(alone.last?.state == .active)
        #expect(crowded == alone)
    }

    @Test func modeFollowsGestures() {
        #expect(CursorController.Output(state: .idle).mode == nil)
        #expect(CursorController.Output(state: .armed).mode == nil)
        #expect(CursorController.Output(state: .active).mode == .pointing)
        #expect(CursorController.Output(state: .active, pressed: true).mode == .pressing)
        #expect(CursorController.Output(state: .active, scrolling: .up).mode == .scrolling(.up))
        #expect(CursorController.Output(state: .active, zooming: true).mode == .zooming)
        // 實際的手：按住按鍵時是按住，兩指是捲動。
        let tap = outputs(woken((pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, tapped: true), 0.8)))
        #expect(tap.contains { $0.mode == .pressing })
        let scroll = outputs(woken((pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, twoFingers: true), 0.5)))
        #expect(scroll.last?.mode == .scrolling(.still))
        #expect(CursorController.Output(state: .active, swiping: true).mode == .swiping)
        let swipe = outputs(woken((pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, threeFingers: true), 0.5)))
        #expect(swipe.last?.mode == .swiping)
    }

    /// 影像未鏡像：手往使用者的右邊移動，影像中的 x 變小。每幀移 0.035（約 0.29 掌寬，每秒約 8.8 掌寬）。
    private func sweep(from x: Double, _ y: Double, dx: Double, dy: Double, frames: Int, threeFingers: Bool = true) -> [Segment] {
        (1...frames).map { i in
            (pointing(x + dx * Double(i), y + dy * Double(i), twoFingers: !threeFingers, threeFingers: threeFingers), 1.0 / 30)
        }
    }

    @Test func threeFingersSweepingSwitchesDesktopWhileCursorHolds() throws {
        let ready = woken((pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, threeFingers: true), 0.5))
        // 往使用者的右揮 → ⌃←；往左揮 → ⌃→（隔 2 秒，過了換方向的等待）；往上揮 → ⌃↑（再隔 2 秒）。
        let right = outputs(ready + sweep(from: 0.5, 0.5, dx: -0.035, dy: 0, frames: 4) + [(pointing(0.36, 0.5, threeFingers: true), 0.3)])
        #expect(right.compactMap(\.desktop) == [.left])
        let left = outputs(ready + sweep(from: 0.5, 0.5, dx: 0.035, dy: 0, frames: 4) + [(pointing(0.64, 0.5, threeFingers: true), 0.3)])
        #expect(left.compactMap(\.desktop) == [.right])
        let up = outputs(ready + sweep(from: 0.5, 0.5, dx: 0, dy: 0.05, frames: 4) + [(pointing(0.5, 0.7, threeFingers: true), 0.3)])
        #expect(up.compactMap(\.desktop) == [.up])
        // 三指模式中游標停在原處，不點擊、不捲動、不右鍵、不 ESC。
        let swiping = right.filter(\.swiping)
        let cursor = try #require(swiping.first?.cursor)
        #expect(swiping.count > 10)
        #expect(swiping.allSatisfy { $0.cursor == cursor && $0.button == nil && $0.scroll == nil && !$0.rightClick && !$0.escape })
    }

    @Test func twoFingerFlickDoesNotSwitchDesktop() {
        // 兩指快速往左右、往上移動是甩動捲動，不換桌面。
        let ready = woken((pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, twoFingers: true), 0.5))
        for (dx, dy) in [(-0.035, 0.0), (0.035, 0), (0, 0.05)] {
            let frames = outputs(ready + sweep(from: 0.5, 0.5, dx: dx, dy: dy, frames: 4, threeFingers: false))
            #expect(frames.allSatisfy { $0.desktop == nil && !$0.swiping })
        }
    }

    @Test func slowThreeFingerMovementDoesNotSwitchDesktop() {
        // 每幀移 0.01（每秒約 2.5 掌寬）。
        let ready = woken((pointing(0.5, 0.5), 1), (pointing(0.5, 0.5, threeFingers: true), 0.5))
        let frames = outputs(ready + sweep(from: 0.5, 0.5, dx: -0.01, dy: 0, frames: 12))
        #expect(frames.allSatisfy { $0.desktop == nil })
        #expect(frames.last?.swiping == true)
    }

    @Test func raisingRingFingerWhileScrollingEndsScrolling() throws {
        // 兩指捲動中伸出無名指：進入三指模式，捲動結束、游標停住。
        let frames = outputs(woken(
            (pointing(0.5, 0.6), 1), (pointing(0.5, 0.6, twoFingers: true), 0.3), (bent(0.5, 0.6), 0.3),
            (pointing(0.5, 0.6, threeFingers: true), 0.6)
        ))
        #expect(frames.contains { $0.scrolling != nil })
        let last = try #require(frames.last)
        #expect(last.swiping && last.scrolling == nil && last.scroll == nil && last.state == .active)
    }

    @Test func losingHandDeactivates() throws {
        let short = try #require(run(woken((pointing(0.5, 0.5), 1), (nil, 1.5), (pointing(0.5, 0.5), 1))))
        let long = try #require(run(woken((pointing(0.5, 0.5), 1), (nil, 2.2), (pointing(0.5, 0.5), 1))))
        #expect(short.state == .active)
        #expect(long.state == .idle)
        #expect(long.cursor == nil)
    }
}

@Suite struct TriggerDetectorTests {
    /// 以 30 fps 依序送入拇指距離，食指高度固定 0.9（`rises` 可逐幀指定）、姿勢正確；回傳每幀是否確認按下與按著。
    private func run(_ distances: [Double?], rises: [Double]? = nil) -> [(pressed: Bool, held: Bool)] {
        var detector = TriggerDetector()
        return distances.enumerated().map { i, distance in
            let pressed = detector.update(distance: distance, rise: rises?[i] ?? 0.9, posed: true, at: Double(i) / 30)
            return (pressed, detector.isPressed)
        }
    }

    @Test func pressNeedsThumbToComeDown() {
        let frames = run(Array(repeating: 0.6, count: 10) + [0.5, 0.35, 0.25, 0.25, 0.25, 0.4, 0.6])
        #expect(frames.map(\.pressed) == Array(repeating: false, count: 13) + [true] + Array(repeating: false, count: 3))
        #expect(frames[14].held && !frames[15].held)
    }

    @Test func fistIsNotATrigger() {
        // 握拳時拇指比食指早一兩幀收起。
        let frames = run(Array(repeating: 0.7, count: 10) + [0.31, 0.11, 0.13, 0.2], rises: Array(repeating: 1.1, count: 12) + [0.49, 0.2])
        #expect(frames.allSatisfy { !$0.pressed })
    }

    @Test func thumbRestingAtIndexDoesNotPress() {
        #expect(run(Array(repeating: 0.3, count: 30)).allSatisfy { !$0.pressed })
    }

    @Test func bendingIndexIsNotATrigger() {
        // 彎手指時食指 PIP 也會移動，拇指距離跟著變小。
        let distances = Array(repeating: 0.6, count: 10) + [0.5, 0.4, 0.3, 0.25, 0.25]
        let rises = Array(repeating: 1.0, count: 10) + [0.9, 0.8, 0.7, 0.65, 0.65]
        #expect(run(distances, rises: rises).allSatisfy { !$0.pressed })
    }

    @Test func curlingIndexReleases() {
        let frames = run(Array(repeating: 0.6, count: 10) + [0.3, 0.25, 0.25, 0.25], rises: Array(repeating: 0.9, count: 13) + [0.2])
        #expect(frames[12].pressed && frames[12].held && !frames[13].held)
    }
}

@Suite struct PointerStabilizerTests {
    /// 以 30 fps 送入掌寬單位的位置（校準掌寬 100 px、畫面 1000×1000，正規化座標 = 掌寬 ÷ 10），回傳掌寬單位的輸出。
    private func run(_ points: [Vec2]) -> [Vec2] {
        var stabilizer = PointerStabilizer()
        return points.enumerated().map { i, p in
            let out = stabilizer.update(Vec2(x: p.x / 10, y: p.y / 10), width: 1000, height: 1000, scale: 100, at: Double(i) / 30)
            return Vec2(x: out.x * 10, y: out.y * 10)
        }
    }

    @Test func tremorDoesNotMove() {
        // 10 Hz、振幅 0.02 掌寬的顫抖：停住後輸出不動。
        let outputs = run((0..<90).map { i in Vec2(x: 5 + 0.02 * sin(Double(i) * 2 * .pi / 3), y: 5) })
        let settled = outputs.dropFirst(30)
        #expect(settled.allSatisfy { $0 == settled.first })
    }

    @Test func slowMovementIsScaledDown() {
        // 先停住，再以 0.3 掌寬／秒移動 2 秒：輸出只移動約 0.3 倍（扣掉停住範圍）。
        let points = Array(repeating: Vec2(x: 5, y: 5), count: 30) + (1...60).map { Vec2(x: 5 + 0.3 * Double($0) / 30, y: 5) }
        let moved = run(points).last!.x - 5
        #expect(moved > 0.1 && moved < 0.3)
    }

    @Test func fastMovementRecoversOffset() {
        // 慢慢移動 1 掌寬累積偏差，再快速移動 3 掌寬：最後回到手指的位置。
        let slow = (0...60).map { Vec2(x: 5 + Double($0) / 60, y: 5) }
        let fast = (1...15).map { Vec2(x: 6 + 3 * Double($0) / 15, y: 5) }
        let outputs = run(slow + fast + Array(repeating: Vec2(x: 9, y: 5), count: 10))
        #expect(abs(outputs[60].x - 6) > 0.3)
        #expect(abs(outputs.last!.x - 9) < 0.02)
    }
}

@Suite struct TapDetectorTests {
    /// 以 30 fps 依序送入彎曲量（度），姿勢正確；`palmSpeed` 為手掌速度（掌寬／秒），`speeds` 逐幀指定時取代它；
    /// `heights`、`middles` 為食指尖、中指尖比各自的指根高出幾個掌寬，預設 1（伸直）與 −0.4（收起）。回傳每幀
    /// 是否確認按下與按著。
    private func run(
        _ flexes: [Double], palmSpeed: Double = 0, speeds: [Double]? = nil, heights: [Double]? = nil, middles: [Double]? = nil,
        posed: [Bool]? = nil
    ) -> [(pressed: Bool, held: Bool)] {
        var detector = TapDetector()
        return flexes.enumerated().map { i, flex in
            let pressed = detector.update(
                flex: flex, height: heights?[i] ?? 1, middle: middles?[i] ?? -0.4, posed: posed?[i] ?? true,
                palmSpeed: speeds?[i] ?? palmSpeed, at: Double(i) / 30
            )
            return (pressed, detector.isPressed)
        }
    }

    @Test func quickBendPresses() {
        let frames = run(Array(repeating: 5, count: 10) + [15, 30, 40, 40, 20, 8])
        #expect(frames.map(\.pressed) == Array(repeating: false, count: 12) + [true] + Array(repeating: false, count: 3))
        #expect(frames[14].held && !frames[15].held)
    }

    @Test func slowBendDoesNotPress() {
        // 0.3 秒內只彎 12°：懸停與慢速對準時的晃動。
        #expect(run((0..<40).map { Double($0) * 1.3 }).allSatisfy { !$0.pressed })
    }

    @Test func movingPalmDoesNotPress() {
        // 快速移動時偶爾有 30° 的假彎曲，但手掌在動。
        #expect(run(Array(repeating: 5, count: 10) + [20, 35, 40, 40], palmSpeed: 1).allSatisfy { !$0.pressed })
    }

    @Test func tapWhileHandSettlesPresses() {
        // 移到目標後馬上按：手掌還帶著一點速度，按的動作也讓指根晃動。
        let speeds = Array(repeating: 0.2, count: 10) + [0.4, 0.45, 0.4, 0.3]
        #expect(run(Array(repeating: 5, count: 10) + [20, 35, 40, 40], speeds: speeds).contains { $0.pressed })
    }

    @Test func bendRightAfterFastMoveDoesNotPress() {
        // 快速移動剛停下時的假彎曲：開始彎的時候手掌還很快。
        let speeds = Array(repeating: 1.5, count: 10) + [0.4, 0.4, 0.4, 0.4]
        #expect(run(Array(repeating: 5, count: 10) + [20, 35, 40, 40], speeds: speeds).allSatisfy { !$0.pressed })
    }

    @Test func foldingWholeFingerDoesNotPress() {
        // 整根食指從指根往下甩：指尖幾乎降到指根的高度。
        let heights = Array(repeating: 1.0, count: 10) + [0.5, 0.25, 0.2, 0.25]
        #expect(run(Array(repeating: 5, count: 10) + [20, 35, 40, 40], heights: heights).allSatisfy { !$0.pressed })
    }

    @Test func raisingMiddleFingerDoesNotPress() {
        // 從指向換成兩指：食指先彎，中指同時開始伸直。
        let middles = Array(repeating: -0.4, count: 10) + [-0.35, -0.3, -0.25, -0.2]
        #expect(run(Array(repeating: 5, count: 10) + [20, 35, 40, 40], middles: middles).allSatisfy { !$0.pressed })
    }

    @Test func leavingPoseReleases() {
        let frames = run(Array(repeating: 5, count: 10) + [30, 40, 40], posed: Array(repeating: true, count: 12) + [false])
        #expect(frames[11].pressed && !frames[12].held)
    }
}

@Suite struct TapClickerTests {
    /// 食指對應的游標 (`x`, `y`) 與彎曲量（度）；nil 表示看不到手。
    private typealias Frame = (x: Double, y: Double, flex: Double)?

    /// 手不動，食指伸直指著 (500, 300) 半秒。
    private let pointing = [Frame](repeating: (500, 300, 5), count: 15)

    /// 以 30 fps 依序送入各幀，手掌每幀移動 `palmStep` 掌寬，回傳每一幀的輸出。
    private func run(_ frames: [Frame], palmStep: Double = 0) -> [TapClicker.Output] {
        var clicker = TapClicker()
        return frames.enumerated().map { i, frame in
            clicker.update(
                cursor: frame.map { Vec2(x: $0.x, y: $0.y) }, flex: frame?.flex, height: 1, middle: -0.4, posed: true,
                palm: frame.map { _ in Vec2(x: palmStep * Double(i), y: 0) }, valid: true, at: Double(i) / 30
            )
        }
    }

    @Test func clickLandsWhereFingerPointedBeforeTap() {
        // 按下時 PIP 帶著游標往下偏，伸直時再回來。
        let outputs = run(pointing + [(500, 290, 16), (500, 280, 30), (500, 270, 40), (500, 270, 40), (500, 285, 12), (500, 300, 5)])
        #expect(outputs.compactMap(\.button) == [.down, .up])
        #expect(outputs.dropFirst(15).allSatisfy { $0.cursor == Vec2(x: 500, y: 300) })
    }

    @Test func holdingTapDrags() {
        // 按住 0.6 秒後手往右移 100 pt，伸直途中的移動不算。
        let hold = [Frame](repeating: (500, 270, 40), count: 18)
        let outputs = run(pointing + [(500, 290, 16), (500, 280, 30), (500, 270, 40)] + hold + [(550, 270, 40), (600, 270, 40), (650, 285, 20), (600, 300, 5)])
        #expect(outputs.compactMap(\.button) == [.down, .up])
        #expect(outputs.last?.cursor == Vec2(x: 600, y: 300))
    }

    @Test func movingHandDoesNotFreeze() {
        // 手快速移動時彎曲量也會晃。
        let frames: [Frame] = (0..<20).map { i in (Double(i) * 50, 300, i == 15 ? 17 : 5) }
        let outputs = run(frames, palmStep: 0.05)
        #expect(outputs.map(\.cursor) == frames.map { $0.map { Vec2(x: $0.x, y: $0.y) } })
        #expect(outputs.allSatisfy { $0.button == nil })
    }

    @Test func releasesWhenHandIsLost() {
        let outputs = run(pointing + [(500, 290, 16), (500, 280, 30), (500, 270, 40)] + [Frame](repeating: nil, count: 12))
        #expect(outputs.compactMap(\.button) == [.down, .up])
    }

    @Test func cursorFollowsAgainAfterRelease() {
        // 放開 0.25 秒後游標就恢復跟隨，不會一直停在按下的位置。
        let press: [Frame] = [(500, 290, 16), (500, 280, 30), (500, 270, 40), (500, 270, 40), (500, 285, 8)]
        let outputs = run(pointing + press + [Frame](repeating: (600, 300, 5), count: 12))
        #expect(outputs.compactMap(\.button) == [.down, .up])
        #expect(outputs.last?.cursor == Vec2(x: 600, y: 300))
    }
}

@Suite struct ScrollerTests {
    private typealias Frame = (scroll: Double, scrolling: Bool, direction: Scroller.Direction)

    /// 以 30 fps 依序送入各段：伸直幾指（2 = 食指與中指，1 = 只有食指，0 = 其他姿勢，例如甩下去時手指彎著）、秒數、
    /// 食指尖高度每秒的變化（掌寬）。高度從 0 開始。回傳每一幀的捲動距離，與送入後的捲動狀態。
    private func run(_ segments: [(fingers: Int, seconds: Double, speed: Double)]) -> [Frame] {
        var scroller = Scroller()
        var frames: [Frame] = []
        var level = 0.0
        for segment in segments {
            for _ in 0..<Int((segment.seconds * 30).rounded()) {
                level += segment.speed / 30
                let scroll = scroller.update(
                    twoFingers: segment.fingers == 2, pointing: segment.fingers == 1, level: level, at: Double(frames.count) / 30
                )
                frames.append((scroll ?? 0, scroller.isScrolling, scroller.direction))
            }
        }
        return frames
    }

    private func total(_ frames: some Sequence<Frame>) -> Double {
        frames.reduce(0) { $0 + $1.scroll }
    }

    @Test func flickDownScrollsAndSlowReturnDoesNot() {
        // 0.13 秒往下甩 2 掌寬（彎手指），停一下，再花 1 秒收回來。
        let frames = run([(2, 0.2, 0), (0, 4.0 / 30, -15), (0, 0.2, 0), (2, 1, 2), (2, 2, 0)])
        // 內容往下，以這一甩的速度開始捲、逐漸減速停下，每幀不會忽大忽小；收回來不往上捲。
        #expect(total(frames) < -600)
        #expect(frames.allSatisfy { $0.scroll <= 0 })
        let glide = frames.dropFirst(8).map { abs($0.scroll) }
        #expect(zip(glide, glide.dropFirst()).allSatisfy { $1 <= $0 + 1 })
        #expect(frames.suffix(5).allSatisfy { $0.scroll == 0 && $0.direction == .still && $0.scrolling })
    }

    @Test func glideDoesNotDependOnHowTheFlickEnds() {
        // 同樣速度的一甩：甩到底馬上慢慢收回，或先停 0.2 秒再收回，滑的距離一樣。
        let quick = run([(2, 0.2, 0), (0, 4.0 / 30, -15), (2, 1, 1.5), (2, 2, 0)])
        let paused = run([(2, 0.2, 0), (0, 4.0 / 30, -15), (0, 0.2, 0), (2, 1, 1.5), (2, 1.8, 0)])
        #expect(total(quick) < -600)
        #expect(abs(total(quick) - total(paused)) <= abs(total(quick)) * 0.05)
    }

    @Test func flickUpScrollsContentUp() {
        let frames = run([(2, 0.2, 0), (2, 4.0 / 30, 15), (2, 0.2, 0), (0, 1, -2), (2, 1, 0)])
        #expect(total(frames) > 600)
        #expect(frames.allSatisfy { $0.scroll >= 0 })
        #expect(frames.dropFirst(6).prefix(10).allSatisfy { $0.direction == .up })
    }

    @Test func slowMovementDoesNotScroll() {
        // 每秒 4 掌寬以下：手移動、手指慢慢彎伸都不捲。
        let frames = run([(2, 0.2, 0), (2, 0.5, 4), (0, 0.5, -4), (2, 0.5, 2), (2, 0.5, -2)])
        #expect(frames.allSatisfy { $0.scroll == 0 && $0.direction == .still })
        #expect(frames.dropFirst(3).allSatisfy { $0.scrolling })
    }

    @Test func droppingHandAfterSlowRaiseDoesNotScroll() {
        // 慢慢抬手（沒有算成一甩），再以每秒 7 掌寬放下來：往下要像彎手指那麼快（`downSpeed`）才算一甩。
        let frames = run([(2, 0.2, 0), (2, 0.5, 3), (2, 0.2, 0), (0, 0.2, -7), (2, 0.5, 0)])
        #expect(frames.allSatisfy { $0.scroll == 0 })
    }

    @Test func fastReturnRightAfterFlickDoesNotScrollBack() {
        // 往下甩之後，手指伸直回來也可能很快（每秒 7.5 掌寬），但在 `refractory` 秒內，不算往上甩。
        let frames = run([(2, 0.2, 0), (0, 4.0 / 30, -15), (0, 0.3, 0), (2, 8.0 / 30, 7.5), (2, 1, 0)])
        #expect(frames.allSatisfy { $0.scroll <= 0 })
    }

    @Test func quickCurlBeforeNextFlickUpDoesNotScrollDown() {
        // 往上甩、花 0.9 秒慢慢收回，下一次往上甩之前先很快彎一下手指（預備動作，在上一下開始後約 1.07 秒）：不算往下甩。
        let frames = run([(2, 0.2, 0), (2, 4.0 / 30, 15), (2, 0.9, -2), (0, 4.0 / 30, -12), (2, 4.0 / 30, 15), (2, 0.5, 0)])
        #expect(frames.allSatisfy { $0.scroll >= 0 })
        #expect(total(frames.suffix(19)) > 0)
    }

    @Test func oppositeFlickAfterPauseScrolls() {
        // 往下甩、停 2 秒後往上甩：換方向。
        let frames = run([(2, 0.2, 0), (0, 4.0 / 30, -15), (2, 2, 0), (2, 4.0 / 30, 15), (2, 0.2, 0)])
        #expect(total(frames.prefix(20)) < 0)
        #expect(total(frames.suffix(10)) > 0)
    }

    @Test func pointingEndsScrolling() {
        let frames = run([(2, 0.2, 0), (1, 0.3, 0)])
        #expect(frames.suffix(3).allSatisfy { !$0.scrolling })
    }

    @Test func briefTwoFingersDoNotScroll() {
        let frames = run([(1, 0.2, 0), (2, 2.0 / 30, 0), (0, 0.2, -15)])
        #expect(frames.allSatisfy { $0.scroll == 0 && !$0.scrolling })
    }
}

@Suite struct DesktopSwiperTests {
    private typealias Segment = (three: Bool, seconds: Double, vx: Double, vy: Double)

    /// 以 30 fps 依序送入各段：是否三指、秒數、手掌中心的速度（掌寬/秒，x 往使用者的右邊、y 往上為正）。位置從 (0, 0)
    /// 開始。回傳每一幀的輸出。
    private func run(_ segments: [Segment]) -> [DesktopSwiper.Direction?] {
        var swiper = DesktopSwiper()
        var x = 0.0, y = 0.0
        var outputs: [DesktopSwiper.Direction?] = []
        for segment in segments {
            for _ in 0..<Int((segment.seconds * 30).rounded()) {
                x += segment.vx / 30
                y += segment.vy / 30
                outputs.append(swiper.update(threeFingers: segment.three, position: Vec2(x: x, y: y), at: Double(outputs.count) / 30))
            }
        }
        return outputs
    }

    private func fired(_ segments: [Segment]) -> [DesktopSwiper.Direction] {
        run(segments).compactMap { $0 }
    }

    /// 三指伸直、停 0.4 秒（超過 `hold`）。
    private let ready: Segment = (true, 0.4, 0, 0)
    /// 0.13 秒揮出 2 掌寬，每秒 15 掌寬。
    private let quick = 4.0 / 30

    @Test func handMovingRightGoesToTheLeftDesktop() {
        // 慢慢收回不算。
        #expect(fired([ready, (true, quick, 15, 0), (true, 1, -1.5, 0), (true, 1, 0, 0)]) == [.left])
    }

    @Test func handMovingLeftGoesToTheRightDesktop() {
        #expect(fired([ready, (true, quick, -15, 0), (true, 1, 1.5, 0), (true, 1, 0, 0)]) == [.right])
    }

    @Test func handMovingUpOpensMissionControl() {
        #expect(fired([ready, (true, quick, 0, 15), (true, 1, 0, -1.5), (true, 1, 0, 0)]) == [.up])
    }

    @Test func handMovingDownDoesNothing() {
        #expect(fired([ready, (true, quick, 0, -15), (true, 1, 0, 1.5), (true, 1, 0, 0)]).isEmpty)
    }

    @Test func slowMovementDoesNothing() {
        // 每秒 3 掌寬：低於往左右（4.5）與往上（4.0）的門檻。
        #expect(fired([ready, (true, 1, 3, 0), (true, 1, -3, 0), (true, 1, 0, 3)]).isEmpty)
    }

    @Test func diagonalSwingDoesNothing() {
        #expect(fired([ready, (true, quick, 10, 8), (true, 1, 0, 0)]).isEmpty)
    }

    @Test func oneSwingSwitchesOnlyOnce() {
        // 揮一下的速度有起伏：中途降到門檻以下（4 掌寬/秒）但沒有降到 `rearm`，再加速也不再觸發。
        #expect(fired([ready, (true, 3.0 / 30, 15, 0), (true, 2.0 / 30, 4, 0), (true, 3.0 / 30, 15, 0), (true, 1, 0, 0)]) == [.left])
    }

    @Test func fastReturnRightAfterSwingDoesNotSwitchBack() {
        // 揮完停 0.1 秒就很快收回來（每秒 12 掌寬，0.2 秒收完）：在 `refractory` 內不算另一個方向。
        #expect(fired([ready, (true, quick, 15, 0), (true, 0.1, 0, 0), (true, 6.0 / 30, -12, 0), (true, 0.5, 0, 0)]) == [.left])
    }

    @Test func oppositeSwingAfterShortPauseSwitches() {
        // 實機試用：揮完馬上往反方向揮，不該要等 1 秒以上。停 0.6 秒後反向揮就換。
        #expect(fired([ready, (true, quick, 15, 0), (true, 0.6, 0, 0), (true, quick, -15, 0), (true, 0.3, 0, 0)]) == [.left, .right])
    }

    @Test func oppositeSwingAfterLongPauseSwitches() {
        #expect(fired([ready, (true, quick, 15, 0), (true, 2, 0, 0), (true, quick, -15, 0), (true, 0.3, 0, 0)]) == [.left, .right])
    }

    @Test func sameDirectionSwingsSwitchEachTime() {
        // 連續往右揮兩次，中間慢慢收回：各換一個桌面，不必等 `refractory`。
        #expect(fired([ready, (true, quick, 15, 0), (true, 1, -1.5, 0), (true, quick, 15, 0), (true, 0.3, 0, 0)]) == [.left, .left])
    }

    @Test func briefThreeFingersDoNotStartTheMode() {
        // 三指只有一幀（不到 `hold`），之後手很快揮過去：不算。
        #expect(fired([(false, 0.3, 0, 0), (true, 1.0 / 30, 0, 0), (false, 0.3, 0, 0), (false, quick, 15, 0), (false, 0.3, 0, 0)]).isEmpty)
    }

    @Test func swingThatFormsThreeFingersMidwaySwitches() {
        // 實機錄影的往上揮：抬手的途中才伸出三指，姿勢只比速度峰值早約 0.05 秒；進入模式時揮動已經快結束，三指之前的位置也要算進速度。
        #expect(fired([(false, 0.3, 0, 0), (false, 2.0 / 30, 0, 6), (true, 3.0 / 30, 0, 6), (true, 0.3, 0, 0)]) == [.up])
    }

    @Test func brieflyLosingThreeFingersDuringSwingStillSwitches() {
        // 揮得快時手指常有 1–2 幀被誤判成別的姿勢。
        #expect(fired([ready, (false, 2.0 / 30, 15, 0), (true, 2.0 / 30, 15, 0), (true, 0.5, 0, 0)]) == [.left])
    }

    @Test func leavingThreeFingersEndsTheMode() {
        var swiper = DesktopSwiper()
        for i in 0..<12 { _ = swiper.update(threeFingers: true, position: Vec2(x: 0, y: 0), at: Double(i) / 30) }
        #expect(swiper.isActive)
        for i in 12..<23 { _ = swiper.update(threeFingers: false, position: Vec2(x: 0, y: 0), at: Double(i) / 30) }
        #expect(!swiper.isActive)
        // 離開之後不是三指，揮了也不換桌面。
        #expect(fired([ready, (false, 0.4, 0, 0), (false, quick, 15, 0), (false, 0.5, 0, 0)]).isEmpty)
    }
}

@Suite struct FrameThrottleTests {
    /// 以 `fps` 送入 `seconds` 秒的幀，`jitter` 為每幀時間的偏差（秒，輪流正負）；回傳被處理的幀時間。
    private func processed(fps: Double, seconds: Double, idle: Bool, jitter: Double = 0) -> [Double] {
        var throttle = FrameThrottle()
        var times: [Double] = []
        for i in 0..<Int(fps * seconds) {
            let t = Double(i) / fps + (i % 2 == 0 ? jitter : -jitter)
            if throttle.shouldProcess(at: t, idle: idle) { times.append(t) }
        }
        return times
    }

    @Test func idleProcessesEveryThirdFrameAt30Fps() {
        #expect(processed(fps: 30, seconds: 3, idle: true).count == 30)
    }

    @Test func nonIdleProcessesEveryFrame() {
        #expect(processed(fps: 30, seconds: 3, idle: false).count == 90)
    }

    @Test func idleStaysNearTenFpsWithJitter() {
        // 相機幀的時間常有幾毫秒的抖動：仍約 10 fps，兩次之間不超過 0.15 秒。
        let times = processed(fps: 30, seconds: 3, idle: true, jitter: 0.004)
        #expect((29...31).contains(times.count))
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 <= 0.15 })
    }

    @Test func idleAtLowLightFrameRateStillSamples() {
        // 光線不足時相機降到 15 fps：每 0.133 秒處理一幀。
        let times = processed(fps: 15, seconds: 4, idle: true)
        #expect(times.count >= 28 && times.count <= 32)
    }

    @Test func leavingIdleProcessesTheNextFrameImmediately() {
        var throttle = FrameThrottle()
        let first = throttle.shouldProcess(at: 0, idle: true)
        let skipped = throttle.shouldProcess(at: 1.0 / 30, idle: true)
        // 喚醒後換成每幀都處理，不必等滿 0.1 秒。
        let awake = throttle.shouldProcess(at: 1.0 / 30, idle: false)
        let next = throttle.shouldProcess(at: 2.0 / 30, idle: false)
        #expect(first && !skipped && awake && next)
    }
}

@Suite struct ScrollSmootherTests {
    @Test func spreadsCameraFramesOverDisplayFrames() {
        // 相機每 1/30 秒給 60 pt（每秒 1800 pt），螢幕每 1/120 秒送一次：每次最多約 20 pt，總量不變。
        var smoother = ScrollSmoother()
        var sent: [Double] = []
        for tick in 0..<120 {
            if tick % 4 == 0, tick < 60 { smoother.add(60) }
            sent.append(smoother.step(1.0 / 120) ?? 0)
        }
        #expect(abs(sent.reduce(0, +) - 900) <= 1)
        #expect(sent.max() ?? 0 <= 25)
        #expect(smoother.isIdle)
    }

    @Test func idleSmootherSendsNothing() {
        var smoother = ScrollSmoother()
        #expect(smoother.isIdle && smoother.step(1.0 / 120) == nil)
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

@Suite struct GazeTests {
    @Test func eachGazePhaseVisitsNineTargets() {
        for phase in [Phase.gazeCalibrate, .gazeCheck, .gazeHead] {
            let targets = (0..<9).compactMap { GazeTargets.target(phase, elapsed: Double($0) * GazeTargets.interval + 1) }
            #expect(Set(targets.map { "\($0.x),\($0.y)" }).count == 9)
            #expect(GazeTargets.target(phase, elapsed: 1.9) == GazeTargets.target(phase, elapsed: 0))
        }
        #expect(GazeTargets.target(.move, elapsed: 1) == nil)
    }

    @Test func oldRecordingsStillDecode() throws {
        let line = #"{"t":1,"phase":"move","width":10,"height":10,"latencyMs":1,"inferenceMs":1,"hands":[]}"#
        let frame = try JSONDecoder().decode(FrameRecord.self, from: Data(line.utf8))
        #expect(frame.face == nil && frame.target == nil && frame.faceMs == nil && frame.image == nil)
    }

    @Test func imageNameRoundTrips() throws {
        var frame = FrameRecord(t: 1, phase: .gazeCheck, width: 10, height: 10, latencyMs: 1, inferenceMs: 1, hands: [])
        frame.image = "frames/000012.jpg"
        let decoded = try JSONDecoder().decode(FrameRecord.self, from: JSONEncoder().encode(frame))
        #expect(decoded.image == "frames/000012.jpg")
    }

    /// 瞳孔在眼角之間的位置與目標成正比，頭不動：看眼睛的模型應該幾乎沒有誤差，只看頭的模型估不出來。
    @Test func eyeModelRecoversSyntheticGaze() throws {
        func eye(_ x: Double, _ fx: Double, _ fy: Double) -> (contour: [Vec2], pupil: Vec2) {
            let contour = [Vec2(x: x, y: 0.6), Vec2(x: x + 0.03, y: 0.61), Vec2(x: x + 0.06, y: 0.6), Vec2(x: x + 0.03, y: 0.59)]
            return (contour, Vec2(x: x + 0.03 + 0.012 * (fx - 0.5), y: 0.6 + 0.006 * (fy - 0.5)))
        }
        var frames: [FrameRecord] = []
        for (p, phase) in [Phase.gazeCalibrate, .gazeCheck, .gazeHead].enumerated() {
            for i in 0..<540 {
                let elapsed = Double(i) / 30
                let spot = try #require(GazeTargets.target(phase, elapsed: elapsed))
                let left = eye(0.4, spot.x, spot.y), right = eye(0.54, spot.x, spot.y)
                let face = Face(
                    center: Vec2(x: 0.5, y: 0.55), width: 0.3, height: 0.4, yaw: 0, pitch: 0, roll: 0,
                    leftEye: left.contour, rightEye: right.contour, leftPupil: left.pupil, rightPupil: right.pupil
                )
                frames.append(FrameRecord(
                    t: Double(p) * 18 + elapsed, phase: phase, width: 1000, height: 1000, latencyMs: 0, inferenceMs: 0,
                    hands: [], face: face, faceMs: 10, target: Vec2(x: spot.x * 1440, y: spot.y * 900)
                ))
            }
        }
        let report = GazeAnalysis.report(frames: frames)
        #expect(report.usableRate == 1)
        let eyes = try #require(report.models.first { $0.name.hasPrefix("眼睛（") })
        for error in [eyes.check, eyes.checkSmoothed, eyes.head, eyes.check10Hz] {
            #expect(try #require(error).p90 < 5)
        }
        // 留一時角落的點要外插，嶺迴歸的收縮多出幾 pt。
        #expect(try #require(eyes.leaveOneOut).p90 < 15)
        let headOnly = try #require(report.models.first { $0.name.hasPrefix("只看頭") })
        #expect(try #require(headOnly.check).p50 > 200)
    }
}

@Suite struct ScriptTests {
    @Test func eachPhaseStartsAfterReadingAndCountdown() {
        let script = Script(name: "test", phases: [.warmup, .still, .move])
        let lead = Script.reading + Script.countdown
        // 說明與倒數期間：顯示下一個階段，還沒開始。
        #expect(script.at(elapsed: 1)?.phase == .still)
        #expect(script.at(elapsed: 1)?.startsIn == lead - 1)
        #expect(script.at(elapsed: lead + 1)?.startsIn == nil)
        #expect(script.at(elapsed: lead + 1)?.remaining == Phase.still.duration - 1)
        let next = lead + Phase.still.duration + 1
        #expect(script.at(elapsed: next)?.phase == .move)
        #expect(script.at(elapsed: next)?.startsIn == lead - 1)
        #expect(script.totalDuration == 2 * lead + Phase.still.duration + Phase.move.duration)
        #expect(script.at(elapsed: script.totalDuration) == nil)
    }
}

@Suite struct DepthAnalysisTests {
    /// 指根在 (0.5, 0.4)、掌寬 0.2；近端一節往上 0.1 平貼畫面，PIP 之後兩節（共 0.1）往鏡頭方向彎 `bend` 度。
    private func hand(bend: Double) -> Hand {
        var hand = makeHand(pointing: true)
        let shown = cos(bend * .pi / 180)
        func set(_ joint: Joint, _ x: Double, _ y: Double) { hand.joints[joint.rawValue] = JointSample(x: x, y: y, c: 0.9) }
        set(.indexMCP, 0.5, 0.4)
        set(.littleMCP, 0.3, 0.4)
        set(.indexPIP, 0.5, 0.5)
        set(.indexDIP, 0.5, 0.5 + 0.05 * shown)
        set(.indexTip, 0.5, 0.5 + 0.1 * shown)
        return hand
    }

    @Test func bendTowardCameraIsRecovered() throws {
        let lengths = DepthAnalysis.Lengths(proximal: 0.5, distal: 0.5)
        for bend in [20.0, 40.0, 60.0] {
            let features = try #require(DepthAnalysis.features(hand(bend: bend), width: 1000, height: 1000, lengths: lengths, palm: 200))
            // 畫面上手指仍是直線：2D 彎曲量看不出來。
            #expect(try #require(features[.flex2D]) < 1)
            #expect(abs(try #require(features[.bend3D]) - bend) < 5)
            #expect(abs(try #require(features[.approach])) < 0.01)
        }
    }
}
