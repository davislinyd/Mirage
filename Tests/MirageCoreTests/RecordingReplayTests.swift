import Foundation
import Testing
@testable import MirageCore

/// 用 `recordings/` 的錄影重播 `CursorController`。錄影不進版控，沒有檔案時略過（例如 CI）。
private enum Replay {
    struct Missing: Error {}

    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../recordings").standardized
    static let recordings = ["m0-2026-09-27T16-03-54Z", "m0-2026-09-27T16-41-24Z", "m0-2026-09-27T17-23-39Z"]
    /// daily 階段：兩指伸直，彎兩指 13 下，最後握拳到結束。
    static let scrolling = "m0-2026-09-27T21-14-16Z"
    static let available = (recordings + [scrolling]).allSatisfy {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0).jsonl").path)
    }

    static func load(_ name: String) throws -> [FrameRecord] {
        let text = try String(contentsOf: directory.appendingPathComponent("\(name).jsonl"), encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map { try decoder.decode(FrameRecord.self, from: Data($0.utf8)) }
    }

    /// 以 move 階段（在舒適範圍內移動食指）校準，同 App 的校準流程。
    static func calibrate(_ frames: [FrameRecord]) throws -> Calibration {
        var session = CalibrationSession()
        for frame in frames where frame.phase == .move {
            if case .done(let calibration) = session.update(hands: frame.hands, width: frame.width, height: frame.height, at: frame.t) {
                return calibration
            }
        }
        throw Missing()
    }

    /// 重播 `phase` 的每一幀，且每一幀都在控制中：不在 Active 時換一個新的 controller，先送入同一份錄影裡的張手、
    /// 握拳與指向的手（喚醒後指向），等同使用者一直開著控制做這些動作。
    static func active(_ frames: [FrameRecord], phase: Phase) throws -> [CursorController.Output] {
        let calibration = try calibrate(frames)
        func first(in phase: Phase, _ match: (HandGeometry) -> Bool) throws -> Hand {
            for frame in frames where frame.phase == phase {
                if let hand = frame.hands.primary, match(HandGeometry(hand: hand, width: frame.width, height: frame.height)) { return hand }
            }
            throw Missing()
        }
        let open = try first(in: .wake) { $0.pose == .open }
        let fist = try first(in: .wake) { $0.pose == .fist }
        let center = Vec2(x: (calibration.minX + calibration.maxX) / 2, y: (calibration.minY + calibration.maxY) / 2)
        let point = try first(in: .move) { geometry in
            geometry.palmWidth.flatMap { geometry.isPointing(palmWidth: $0) } == true
                && geometry.normalized(.indexTip).map { $0.distance(to: center) < 0.05 } == true
        }
        let wake = Array(repeating: open, count: 15) + Array(repeating: fist, count: 15) + Array(repeating: point, count: 9)
        let played = frames.filter { $0.phase == phase }
        let size = (width: played[0].width, height: played[0].height)
        var controller: CursorController?
        var outputs: [CursorController.Output] = []
        for frame in played {
            if controller == nil {
                var fresh = CursorController(calibration: calibration, screenWidth: 1440, screenHeight: 900)
                for (i, hand) in wake.enumerated() {
                    _ = fresh.update(hands: [hand], width: size.width, height: size.height, at: frame.t - Double(wake.count - i) / 30)
                }
                controller = fresh
            }
            let output = controller!.update(hands: frame.hands, width: frame.width, height: frame.height, at: frame.t)
            outputs.append(output)
            if output.state != .active { controller = nil }
        }
        return outputs
    }
}

@Suite(.enabled(if: Replay.available)) struct RecordingReplayTests {
    @Test(arguments: Replay.recordings) func everydayMotionDoesNotScroll(name: String) throws {
        let frames = try Replay.load(name)
        for phase in [Phase.still, .move, .pinch, .wake, .daily] {
            let outputs = try Replay.active(frames, phase: phase)
            #expect(outputs.allSatisfy { $0.scrolling == nil && $0.scroll == nil && !$0.rightClick }, "\(name) \(phase)")
        }
    }

    @Test func everyBendScrollsTheSameWay() throws {
        let outputs = try Replay.active(try Replay.load(Replay.scrolling), phase: .daily)
        // 伸直兩指後一直在捲動中，直到結束：彎手指時指尖低於操作範圍，但手沒有離開。
        let start = try #require(outputs.firstIndex { $0.scrolling != nil })
        let scrolling = outputs[start...]
        #expect(scrolling.allSatisfy { $0.state == .active && $0.scrolling != nil })
        #expect(scrolling.allSatisfy { $0.cursor == scrolling.first?.cursor && $0.button == nil })
        // 每彎一下，內容往下；伸直回來不捲。
        #expect(scrolling.compactMap(\.scroll).allSatisfy { $0 < 0 })
        // 握拳時拇指貼著食指，不是右鍵。
        #expect(scrolling.allSatisfy { !$0.rightClick })
        // 最後握拳超過 `dwell`：起點換到彎曲端，改成伸直才捲。
        #expect(outputs.last?.scrolling == .straighten)
    }
}
