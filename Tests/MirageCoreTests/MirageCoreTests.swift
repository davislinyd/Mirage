import Foundation
import Testing
@testable import MirageCore

/// 掌心朝鏡頭、指尖朝上的合成右手（正規化座標）。`curled` 為 true 時四指指尖收回掌心。
private func makeHand(curled: Bool = false, thumbTip: Vec2 = Vec2(x: 0.62, y: 0.45), confidence: Double = 0.9) -> Hand {
    var joints = Array(repeating: JointSample(x: 0, y: 0, c: confidence), count: Joint.allCases.count)
    func set(_ joint: Joint, _ x: Double, _ y: Double) {
        joints[joint.rawValue] = JointSample(x: x, y: y, c: confidence)
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
        set(finger.mcp, finger.x, 0.35)
        set(finger.pip, finger.x, 0.42)
        set(finger.dip, finger.x, curled ? 0.38 : 0.47)
        set(finger.tip, finger.x, curled ? 0.33 : 0.52)
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
    @Test func schedule() {
        #expect(Phase.at(elapsed: 0)?.phase == .warmup)
        #expect(Phase.at(elapsed: 3)?.phase == .still)
        #expect(Phase.at(elapsed: 3.5)?.remaining == 4.5)
        #expect(Phase.at(elapsed: Phase.totalDuration) == nil)
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

    @Test func wakeRequiresFistShortlyAfterOpenHand() {
        var detector = WakeDetector()
        let poses: [(pose: HandPose, t: Double)] = [
            (.fist, 0), (.open, 1), (.fist, 1.5), (.fist, 1.6), (.open, 2), (.other, 2.5), (.fist, 3.2),
        ]
        let woke = poses.map { detector.update(pose: $0.pose, at: $0.t) }
        #expect(woke == [false, false, true, false, false, false, false])
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
        #expect(filtered < raw / 3)
    }
}
