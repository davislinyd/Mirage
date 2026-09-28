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
    static let available = (recordings + [scrolling]).allSatisfy(exists)
    /// `mirage-spike gestures`：抬高手（16:9），以及放低手（1:1，App 預設的格式）各一份調參數用的錄影；最後一份
    /// 1:1 沒有用來調參數。
    static let gestures = ["gestures-2026-09-28T02-23-51Z", "gestures-2026-09-28T02-36-43Z", "gestures-2026-09-28T07-36-00Z"]
    static let gesturesAvailable = gestures.allSatisfy(exists)

    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name).jsonl").path)
    }

    static func load(_ name: String) throws -> [FrameRecord] {
        let text = try String(contentsOf: directory.appendingPathComponent("\(name).jsonl"), encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map { try decoder.decode(FrameRecord.self, from: Data($0.utf8)) }
    }

    /// 用整份錄影所有食指指向的幀校準（算法同 `CalibrationSession`：掌寬中位數、指尖位置 5–95%），等同在實際用到的
    /// 範圍校準。只用 move 階段不行：錄手勢時手常比移動時高，超出操作範圍就不會進入兩指捲動，測不到手勢本身。
    static func calibrate(_ frames: [FrameRecord]) throws -> Calibration {
        var palms: [Double] = []
        var tips: [Vec2] = []
        for frame in frames where frame.phase != .warmup {
            guard let hand = frame.hands.primary else { continue }
            let geometry = HandGeometry(hand: hand, width: frame.width, height: frame.height)
            guard let palm = geometry.palmWidth, let tip = geometry.normalized(.indexTip), geometry.isPointing(palmWidth: palm) == true
            else { continue }
            palms.append(palm)
            tips.append(tip)
        }
        let p = SpikeAnalysis.percentile
        guard let palm = p(palms, 0.5), let minX = p(tips.map(\.x), 0.05), let maxX = p(tips.map(\.x), 0.95),
              let minY = p(tips.map(\.y), 0.05), let maxY = p(tips.map(\.y), 0.95) else { throw Missing() }
        return Calibration(
            palmWidth: palm, minX: minX, minY: minY, maxX: maxX, maxY: maxY, width: frames[0].width, height: frames[0].height
        )
    }

    /// 重播 `phase` 的每一幀，且每一幀都在控制中：不在 Active 時換一個新的 controller 直接進入 Active，等同使用者
    /// 一直開著控制做這些動作。
    /// `withoutThumb` 為 true 時拿掉拇指尖，不會觸發扳機，游標一直跟著食指。
    static func active(_ frames: [FrameRecord], phase: Phase, withoutThumb: Bool = false) throws -> [CursorController.Output] {
        let calibration = try calibrate(frames)
        var controller: CursorController?
        var outputs: [CursorController.Output] = []
        for frame in frames where frame.phase == phase {
            if controller == nil {
                var fresh = CursorController(calibration: calibration, screenWidth: 1440, screenHeight: 900)
                fresh.activate(at: frame.t - 1.0 / 30)
                controller = fresh
            }
            let hands = withoutThumb ? frame.hands.map { hand in
                var hand = hand
                hand.joints[Joint.thumbTip.rawValue].c = 0
                return hand
            } : frame.hands
            let output = controller!.update(hands: hands, width: frame.width, height: frame.height, at: frame.t)
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


@Suite(.enabled(if: Replay.gesturesAvailable)) struct GestureReplayTests {
    private func count(_ outputs: [CursorController.Output]) -> (left: Int, right: Int) {
        (outputs.filter { $0.button == .down }.count, outputs.filter(\.rightClick).count)
    }

    @Test(arguments: Replay.gestures) func gesturesFireOnlyWhenIntended(name: String) throws {
        let frames = try Replay.load(name)
        // 扳機 10–16 下、按住 5–6 下、兩指扳機 9 下；抓到九成以上。
        let trigger = count(try Replay.active(frames, phase: .trigger))
        #expect(trigger.left >= 10 && trigger.right == 0, "\(trigger)")
        let hold = count(try Replay.active(frames, phase: .triggerHold))
        #expect(hold.left >= 5 && hold.right == 0, "\(hold)")
        // 進入兩指捲動前的第一下可能還是左鍵。
        let two = count(try Replay.active(frames, phase: .twoFingerTrigger))
        #expect(two.right >= 8 && two.left <= 1, "\(two)")
        for phase in [Phase.move, .halfBend, .reverseBend, .fist, .daily] {
            let outputs = try Replay.active(frames, phase: phase)
            #expect(count(outputs) == (0, 0), "\(phase)")
        }
        // 半彎捲動：每一下都讓內容往下。
        let bends = try Replay.active(frames, phase: .halfBend).compactMap(\.scroll)
        #expect(!bends.isEmpty && bends.allSatisfy { $0 < 0 })
    }

    @Test(arguments: Replay.gestures) func cursorFollowsWhileMoving(name: String) throws {
        // 一般移動游標時拇指也會晃，不能因此提前鎖住游標：鎖定條件太鬆時，移動階段有 24% 的時間被凍結，游標一頓一頓。
        let frames = try Replay.load(name)
        let outputs = try Replay.active(frames, phase: .move)
        let free = try Replay.active(frames, phase: .move, withoutThumb: true)
        let pairs = zip(outputs, free).compactMap { a, b in a.cursor.flatMap { p in b.cursor.map { (p, $0) } } }
        let frozen = pairs.filter { $0.0.distance(to: $0.1) > 0.5 }.count
        #expect(Double(frozen) <= 0.05 * Double(pairs.count), "\(frozen)/\(pairs.count)")
    }

    @Test(arguments: Replay.gestures) func cursorLocksWhenThumbStartsMoving(name: String) throws {
        // 拇指往下時食指跟著動。游標要在拇指一開始動時就鎖住，而且每一下各自鎖定，不能沿用上一下。拿掉拇指重播得到
        // 不鎖定的游標：鎖定那一刻游標跳回的距離，就是鎖住前已經偏掉的量。錄影中不鎖定時點擊會偏 p50 42–67 pt。
        let frames = try Replay.load(name)
        let clicked = try Replay.active(frames, phase: .trigger)
        let free = try Replay.active(frames, phase: .trigger, withoutThumb: true)
        var jumps: [Double] = []
        for i in clicked.indices where clicked[i].button == .down {
            let at = try #require(clicked[i].cursor)
            var start = i
            while start > 0, clicked[start - 1].cursor == at { start -= 1 }
            #expect(i - start <= 20)
            if let before = free[max(0, start - 1)].cursor { jumps.append(at.distance(to: before)) }
        }
        #expect(jumps.count >= 10)
        #expect(jumps.sorted()[jumps.count / 2] <= 20)
    }
}
