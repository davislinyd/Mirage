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
    /// `mirage-spike precision`（手放低、1:1）：懸停、慢速對準、快速移動、按鍵點擊等。第二份原本只用來驗證，按鍵的
    /// 指尖高度門檻參考了它快速移動時甩手指的誤觸。
    static let precision = ["precision-2026-09-28T09-59-48Z", "precision-2026-09-28T10-04-58Z"]
    static let precisionAvailable = precision.allSatisfy(exists)
    /// `mirage-spike controls`：十字每 3 秒換位置，移過去後按鍵。兩份的「移過去右鍵」階段也是按鍵，不是扳機。
    static let controls = ["controls-2026-09-28T13-54-33Z", "controls-2026-09-28T13-57-37Z"]
    /// 同一個腳本，但只移過去、沒有按。
    static let controlsWithoutTaps = ["controls-2026-09-28T13-37-57Z", "controls-2026-09-28T13-40-07Z"]
    /// 同一個腳本，「移過去右鍵」是拇指扳機。按鍵的手掌速度與食指高度門檻沒有參考這兩份；中指門檻來自第一份兩指
    /// 扳機開頭的誤觸，扳機的拇指門檻與移動時的扳機不留在按下狀態，來自第二份漏掉的右鍵。
    static let controlsWithTriggers = ["controls-2026-09-28T14-10-14Z", "controls-2026-09-28T14-37-53Z"]
    static let controlsAvailable = (controls + controlsWithoutTaps + controlsWithTriggers).allSatisfy(exists)
    /// `mirage-spike swipe`：兩指往上甩（抬手）、往下甩（彎手指），各 10 下；慢慢移開後停住；兩指扳機；日常。前兩份
    /// 參與了調整：第一份定甩動的門檻，第二份找出往上甩之前的預備動作，把反方向的冷卻延長到 1.5 秒。第三份只用來驗證。
    static let swipe = ["swipe-2026-09-29T12-21-05Z", "swipe-2026-09-29T12-52-10Z", "swipe-2026-09-29T13-01-29Z"]
    static let swipeAvailable = swipe.allSatisfy(exists)
    /// `mirage-spike desktop`：三指往右、往左、往上、往下各揮 10 下再慢慢收回；慢慢移動；兩指甩動；兩指扳機；日常。第一份定
    /// 參數；第二份原本用來驗證（往右 14、往左 6、往上 5，慢慢移動階段誤觸 4），之後也拿來調參數，現在兩份都參與了調整。
    static let desktop = ["desktop-2026-10-01T05-22-20Z", "desktop-2026-10-01T05-42-40Z"]
    static let desktopAvailable = desktop.allSatisfy(exists)
    /// `mirage-spike gather`：五指捏合、張手 → 握拳、兩指扳機、日常；值為應觸發的次數。前兩份刻意張手停一下再捏合（5、
    /// 8 下），第三份照平常的速度（13 下），三份都參與了調整。第一份漏掉的一下拇指沒碰到中指（0.45 掌寬）。
    static let gather = ["gather-2026-10-02T14-08-51Z": 4, "gather-2026-10-02T14-13-07Z": 8, "gather-2026-10-02T14-24-20Z": 13]
    static let gatherAvailable = gather.keys.allSatisfy(exists)
    /// 沒有五指捏合的錄影：每個階段都不該送 ⌘M。
    static let withoutGather = recordings + [scrolling] + gestures + precision + controls + controlsWithoutTaps + controlsWithTriggers + swipe + desktop

    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name).jsonl").path)
    }

    static func load(_ name: String) throws -> [FrameRecord] {
        let text = try String(contentsOf: directory.appendingPathComponent("\(name).jsonl"), encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map { try decoder.decode(FrameRecord.self, from: Data($0.utf8)) }
    }

    /// 用整份錄影所有食指指向的幀校準（算法同 `CalibrationSession`：掌寬中位數、食指 PIP 位置 5–95%），等同在實際用到的
    /// 範圍校準。只用 move 階段不行：錄手勢時手常比移動時高，超出操作範圍就不會進入兩指捲動，測不到手勢本身。
    static func calibrate(_ frames: [FrameRecord]) throws -> Calibration {
        var palms: [Double] = []
        var points: [Vec2] = []
        for frame in frames where frame.phase != .warmup {
            guard let hand = frame.hands.primary else { continue }
            let geometry = HandGeometry(hand: hand, width: frame.width, height: frame.height)
            guard let palm = geometry.palmWidth, let point = geometry.normalized(.indexPIP), geometry.isPointing(palmWidth: palm) == true
            else { continue }
            palms.append(palm)
            points.append(point)
        }
        let p = SpikeAnalysis.percentile
        guard let palm = p(palms, 0.5), let minX = p(points.map(\.x), 0.05), let maxX = p(points.map(\.x), 0.95),
              let minY = p(points.map(\.y), 0.05), let maxY = p(points.map(\.y), 0.95) else { throw Missing() }
        return Calibration(
            palmWidth: palm, minX: minX, minY: minY, maxX: maxX, maxY: maxY, width: frames[0].width, height: frames[0].height
        )
    }

    /// 重播 `phase` 的每一幀，且每一幀都在控制中：不在 Active 時換一個新的 controller 直接進入 Active，等同使用者
    /// 一直開著控制做這些動作。
    /// `removing` 的關節當作看不到，例如拿掉食指 DIP 與指尖就不會觸發按鍵，得到不鎖定的游標；`stabilized` 為 false
    /// 時關掉防抖；`bystander` 為 true 時，階段開始 1 秒後每幀多一隻旁人的手：主要手的複本，往另一邊移半個畫面、
    /// 信心調到最高。
    static func active(
        _ frames: [FrameRecord], phase: Phase, removing: [Joint] = [], stabilized: Bool = true, bystander: Bool = false
    ) throws -> [CursorController.Output] {
        let calibration = try calibrate(frames)
        var controller: CursorController?
        var outputs: [CursorController.Output] = []
        for frame in frames where frame.phase == phase {
            if controller == nil {
                var fresh = CursorController(calibration: calibration, screenWidth: 1440, screenHeight: 900)
                if !stabilized {
                    fresh.stabilizer.stillSpeed = 0
                    fresh.stabilizer.holdRadius = 0
                    fresh.stabilizer.minGain = 1
                }
                fresh.activate(at: frame.t - 1.0 / 30)
                controller = fresh
            }
            var hands = frame.hands.map { hand in
                var hand = hand
                for joint in removing { hand.joints[joint.rawValue].c = 0 }
                return hand
            }
            let start = frames.first { $0.phase == phase }?.t ?? frame.t
            if bystander, frame.t - start >= 1, var copy = frame.hands.primary {
                let x = copy.joints.filter { $0.c > 0 }.map(\.x).reduce(0, +) / Double(max(1, copy.joints.filter { $0.c > 0 }.count))
                let shift = x < 0.5 ? 0.5 : -0.5
                copy.chirality = .right
                copy.joints = copy.joints.map { JointSample(x: $0.x + shift, y: $0.y, c: $0.c > 0 ? 1 : 0) }
                hands.append(copy)
            }
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

    /// 每 `stride` 幀處理一幀（從 `offset` 開始），統計 `phase` 中進入 Armed 的次數；進入後換新的 controller 回到待命。
    private func wakes(_ frames: [FrameRecord], phase: Phase, stride: Int, offset: Int) throws -> Int {
        let calibration = try Replay.calibrate(frames)
        func fresh() -> CursorController { CursorController(calibration: calibration, screenWidth: 1440, screenHeight: 900) }
        var controller = fresh()
        var count = 0
        for (index, frame) in frames.filter({ $0.phase == phase }).enumerated() where index % stride == offset {
            if controller.update(hands: frame.hands, width: frame.width, height: frame.height, at: frame.t).state == .armed {
                count += 1
                controller = fresh()
            }
        }
        return count
    }

    @Test(arguments: Replay.recordings) func wakeStillWorksWhenIdleSamplesAt10Fps(name: String) throws {
        // 待命時每 3 幀處理 1 幀（`FrameThrottle`）：三份錄影的喚醒 8、5、5 次，三種起點都一樣；日常的誤喚醒也不增加。
        let frames = try Replay.load(name)
        for phase in [Phase.wake, .daily] {
            let full = try wakes(frames, phase: phase, stride: 1, offset: 0)
            for offset in 0..<3 {
                #expect(try wakes(frames, phase: phase, stride: 3, offset: offset) == full, "\(name) \(phase) offset \(offset)")
            }
        }
        #expect(try wakes(frames, phase: .wake, stride: 1, offset: 0) >= 5)
    }

    @Test func quickBendsScrollDown() throws {
        let outputs = try Replay.active(try Replay.load(Replay.scrolling), phase: .daily)
        // 伸直兩指後一直在捲動中，直到結束：彎手指時指尖低於操作範圍，但手沒有離開。
        let start = try #require(outputs.firstIndex { $0.scrolling != nil })
        let scrolling = outputs[start...]
        #expect(scrolling.allSatisfy { $0.state == .active && $0.scrolling != nil })
        #expect(scrolling.allSatisfy { $0.cursor == scrolling.first?.cursor && $0.button == nil })
        // 彎得快就是往下甩，內容往下；伸直回來幾乎不往上捲（不超過 5%）。
        let scrolls = scrolling.compactMap(\.scroll)
        let down = -scrolls.filter { $0 < 0 }.reduce(0, +), up = scrolls.filter { $0 > 0 }.reduce(0, +)
        #expect(down > 0 && up <= down * 0.05, "up \(up) down \(down)")
        // 握拳時拇指貼著食指，不是扳機。
        #expect(scrolling.allSatisfy { !$0.rightClick && !$0.escape })
    }
}


@Suite(.enabled(if: Replay.gesturesAvailable)) struct GestureReplayTests {
    private func count(_ outputs: [CursorController.Output]) -> (left: Int, right: Int, escape: Int) {
        (outputs.filter { $0.button == .down }.count, outputs.filter(\.rightClick).count, outputs.filter(\.escape).count)
    }

    @Test(arguments: Replay.gestures) func thumbTriggersRightClickAndEscape(name: String) throws {
        // 三份錄影各扳機 12–16 下（按住 0.1–0.4 秒）、按住 5–7 下（0.6–1.2 秒）、兩指扳機約 10 下。
        let frames = try Replay.load(name)
        let trigger = count(try Replay.active(frames, phase: .trigger))
        #expect(trigger.right >= 9 && trigger.left == 0 && trigger.escape == 0, "\(trigger)")
        // 按住超過 0.5 秒是縮放，不是右鍵。
        let holding = try Replay.active(frames, phase: .triggerHold)
        let hold = count(holding)
        let zooms = zip(holding, holding.dropFirst()).filter { !$0.0.zooming && $0.1.zooming }.count
        #expect(zooms >= 5 && hold.right == 0 && hold.left == 0, "\(hold) zooms \(zooms)")
        let two = count(try Replay.active(frames, phase: .twoFingerTrigger))
        #expect(two.escape >= 8 && two.left == 0 && two.right <= 1, "\(two)")
        for phase in [Phase.move, .halfBend, .reverseBend, .fist, .daily] {
            let other = count(try Replay.active(frames, phase: phase))
            #expect(other == (0, 0, 0), "\(phase) \(other)")
        }
        // 半彎捲動是舊的手勢：彎、伸一樣快，伸直常被當成往上甩，不驗捲動方向；新手勢由 `SwipeReplayTests` 驗。
    }
}

@Suite(.enabled(if: Replay.precisionAvailable)) struct PrecisionReplayTests {
    private func count(_ outputs: [CursorController.Output]) -> (left: Int, right: Int) {
        (outputs.filter { $0.button == .down }.count, outputs.filter(\.rightClick).count)
    }

    @Test(arguments: Replay.precision) func tapsClickOnlyWhenIntended(name: String) throws {
        // 兩份錄影各按了 20、26 下，按住各 5 下。
        let frames = try Replay.load(name)
        let taps = try Replay.active(frames, phase: .tap)
        #expect(taps.filter { $0.button == .down }.count >= 18 && taps.allSatisfy { !$0.rightClick && !$0.escape })
        let holds = try Replay.active(frames, phase: .tapHold)
        #expect(holds.filter { $0.button == .down }.count >= 5 && holds.allSatisfy { !$0.rightClick && !$0.escape })
        let escapes = try Replay.active(frames, phase: .twoFingerTrigger).filter(\.escape).count
        #expect(escapes >= 5)
        // 其他階段不左鍵；右鍵與 ESC 的誤觸合計最多 1 次（移動時拇指晃動、半彎捲動時動到拇指）。
        var stray = 0
        for phase in [Phase.move, .hover, .precise, .sweep, .twoFingerTrigger, .halfBend, .fist, .daily] {
            let outputs = try Replay.active(frames, phase: phase)
            #expect(count(outputs).left == 0, "\(phase)")
            stray += outputs.filter(\.rightClick).count + (phase == .twoFingerTrigger ? 0 : outputs.filter(\.escape).count)
        }
        #expect(stray <= 1)
    }

    @Test(arguments: Replay.precision) func tapClickLandsWhereFingerPointed(name: String) throws {
        // 按下時 PIP 也會跟著晃：點擊落在開始按之前的位置，而且每一下各自鎖定，不沿用上一下。拿掉食指 DIP 與指尖
        // 重播得到不鎖定的游標，鎖定那一刻游標跳回的距離就是鎖住前已經偏掉的量。
        let frames = try Replay.load(name)
        let clicked = try Replay.active(frames, phase: .tap)
        let free = try Replay.active(frames, phase: .tap, removing: [.indexDIP, .indexTip])
        var jumps: [Double] = []
        for i in clicked.indices where clicked[i].button == .down {
            let at = try #require(clicked[i].cursor)
            var start = i
            while start > 0, clicked[start - 1].cursor == at { start -= 1 }
            if let before = free[max(0, start - 1)].cursor { jumps.append(at.distance(to: before)) }
        }
        #expect(jumps.count >= 18)
        #expect(jumps.sorted()[jumps.count / 2] <= 20)
    }

    @Test(arguments: Replay.precision) func stabilizerSteadiesSmallMovements(name: String) throws {
        // 懸停與慢速對準時，游標逐幀移動的中位數至少降一半。
        let frames = try Replay.load(name)
        for phase in [Phase.hover, .precise] {
            func median(_ outputs: [CursorController.Output]) -> Double {
                let steps = zip(outputs, outputs.dropFirst()).compactMap { a, b in a.cursor.flatMap { p in b.cursor.map { p.distance(to: $0) } } }
                return steps.sorted()[steps.count / 2]
            }
            let steady = median(try Replay.active(frames, phase: phase))
            let raw = median(try Replay.active(frames, phase: phase, stabilized: false))
            #expect(steady <= raw / 2, "\(phase) \(steady) vs \(raw)")
        }
    }
}

@Suite(.enabled(if: Replay.controlsAvailable)) struct ControlsReplayTests {
    @Test(arguments: Replay.controlsWithTriggers) func bystanderHandChangesNothing(name: String) throws {
        let frames = try Replay.load(name)
        for phase in [Phase.moveAndTap, .moveAndTrigger, .twoFingerTrigger, .halfBend, .threeFingerBend] {
            let alone = try Replay.active(frames, phase: phase)
            let crowded = try Replay.active(frames, phase: phase, bystander: true)
            #expect(crowded == alone, "\(phase)")
        }
    }

    private func leftClicks(_ name: String, _ phases: [Phase]) throws -> Int {
        let frames = try Replay.load(name)
        return try phases.reduce(0) { total, phase in
            total + (try Replay.active(frames, phase: phase)).filter { $0.button == .down }.count
        }
    }

    @Test(arguments: Replay.controls) func tapsRightAfterMovingClick(name: String) throws {
        // 兩份各按了 10–12 下，其中一下只彎 18°。多數是一移到十字就按，手掌還沒完全停下。
        #expect(try leftClicks(name, [.moveAndTap, .moveAndTrigger]) >= 10)
        #expect(try leftClicks(name, [.move]) == 0)
    }

    @Test(arguments: Replay.controlsWithTriggers) func thumbTriggersRightAfterMovingRightClick(name: String) throws {
        // 各按鍵 5–6 下，其中一下只彎 13–17°；各扳機 6 下，拇指常只壓下 0.13–0.14 掌寬。
        #expect(try leftClicks(name, [.moveAndTap]) >= 4)
        let triggers = try Replay.active(try Replay.load(name), phase: .moveAndTrigger)
        #expect(triggers.filter(\.rightClick).count >= 5)
        #expect(triggers.allSatisfy { $0.button == nil })
        // 第一份兩指扳機開頭從指向換成兩指時，食指先彎到 97°，中指接著伸直。
        #expect(try leftClicks(name, [.move, .twoFingerTrigger, .halfBend, .threeFingerBend, .fist, .daily]) == 0)
    }

    @Test(arguments: Replay.controlsWithoutTaps) func movingBetweenTargetsDoesNotClick(name: String) throws {
        #expect(try leftClicks(name, [.move, .moveAndTap, .moveAndTrigger, .twoFingerTrigger, .halfBend, .threeFingerBend, .fist, .daily]) == 0)
    }
}

@Suite(.enabled(if: Replay.swipeAvailable)) struct SwipeReplayTests {
    /// 往上（內容往上）與往下捲動的總量（pt）。
    private func total(_ outputs: [CursorController.Output]) -> (up: Double, down: Double) {
        let scrolls = outputs.compactMap(\.scroll)
        return (scrolls.filter { $0 > 0 }.reduce(0, +), -scrolls.filter { $0 < 0 }.reduce(0, +))
    }

    @Test(arguments: Replay.swipe) func flicksScrollAndReturnsDoNot(name: String) throws {
        let frames = try Replay.load(name)
        // 各甩 10 下；回程造成的反向捲動不超過 5%。
        let up = total(try Replay.active(frames, phase: .swipeUp))
        #expect(up.up >= 3000 && up.down <= up.up * 0.05, "\(up)")
        let down = total(try Replay.active(frames, phase: .swipeDown))
        #expect(down.down >= 3000 && down.up <= down.down * 0.05, "\(down)")
        // 慢慢移開、停住再移回來不捲；兩指扳機是 ESC，也不捲。甩動與慢慢移動時抬手，拇指跟著晃，不是 ESC。
        #expect(try Replay.active(frames, phase: .swipeHold).allSatisfy { $0.scroll == nil })
        for phase in [Phase.swipeUp, .swipeDown, .swipeHold] {
            #expect(try Replay.active(frames, phase: phase).allSatisfy { !$0.escape }, "\(phase)")
        }
        let trigger = try Replay.active(frames, phase: .twoFingerTrigger)
        #expect(trigger.filter(\.escape).count >= 8 && trigger.allSatisfy { $0.scroll == nil })
    }
}

@Suite(.enabled(if: Replay.desktopAvailable)) struct DesktopReplayTests {
    /// 各方向換桌面的次數。
    private func counts(_ outputs: [CursorController.Output]) -> (left: Int, right: Int, up: Int) {
        let all = outputs.compactMap(\.desktop)
        return (all.filter { $0 == .left }.count, all.filter { $0 == .right }.count, all.filter { $0 == .up }.count)
    }

    @Test(arguments: Replay.desktop) func swingsSwitchAndEverythingElseDoesNot(name: String) throws {
        let frames = try Replay.load(name)
        // 各揮 10 下再慢慢收回（第二份往右揮了 14 下）。往右揮 → ⌃←（`.left`），往左揮 → ⌃→（`.right`），往上揮 → ⌃↑
        // （`.up`）；回程不算另一個方向。往左、往上揮時三指只在動作開頭出現 1–2 幀，無名指隨後就收起來；往上揮是抬手
        // 的途中才伸出三指，姿勢只比速度峰值早 0.03–0.07 秒。
        let rightOutputs = try Replay.active(frames, phase: .desktopRight)
        let right = counts(rightOutputs)
        #expect(right.left >= 6 && right.right == 0 && right.up == 0, "\(right)")
        let leftOutputs = try Replay.active(frames, phase: .desktopLeft)
        let left = counts(leftOutputs)
        #expect(left.right >= 6 && left.left == 0 && left.up == 0, "\(left)")
        let upOutputs = try Replay.active(frames, phase: .desktopUp)
        let up = counts(upOutputs)
        #expect(up.up >= 4 && up.left == 0 && up.right == 0, "\(up)")
        // 一揮只換一個桌面：兩次之間至少隔 `cooldown`。
        for (phase, outputs) in [(Phase.desktopRight, rightOutputs), (.desktopLeft, leftOutputs), (.desktopUp, upOutputs)] {
            let times = zip(frames.filter { $0.phase == phase }, outputs).filter { $0.1.desktop != nil }.map(\.0.t)
            #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 0.5 }, "\(phase) \(times)")
        }
        // 往下揮、兩指甩動、兩指扳機、日常、移動都不換桌面。
        for phase in [Phase.desktopDown, .swipeUp, .twoFingerTrigger, .daily, .move] {
            let other = counts(try Replay.active(frames, phase: phase))
            #expect(other == (0, 0, 0), "\(phase) \(other)")
        }
        // 要求慢慢移動的階段：第二份移得不算慢（約 1.5 個掌寬、0.4–0.5 秒，峰值最高到 5.9 掌寬/秒），和刻意的一揮重疊，
        // 只能降低而不能消除誤觸。
        let hold = counts(try Replay.active(frames, phase: .desktopHold))
        #expect(hold.left + hold.right + hold.up <= 4, "\(hold)")
    }
}

@Suite struct GatherReplayTests {
    @Test(.enabled(if: Replay.gatherAvailable), arguments: Replay.gather.keys.sorted()) func gatherMinimizesAndFistDoesNot(name: String) throws {
        let frames = try Replay.load(name)
        let count = try Replay.active(frames, phase: .gather).filter(\.minimize).count
        #expect(count == Replay.gather[name], "\(name) \(count)")
        for phase in [Phase.move, .wake, .twoFingerTrigger, .daily] {
            #expect(try Replay.active(frames, phase: phase).allSatisfy { !$0.minimize }, "\(phase)")
        }
    }

    @Test(arguments: Replay.withoutGather.filter(Replay.exists)) func otherRecordingsDoNotMinimize(name: String) throws {
        let frames = try Replay.load(name)
        for phase in Set(frames.map(\.phase)).subtracting([.warmup]) {
            #expect(try Replay.active(frames, phase: phase).allSatisfy { !$0.minimize }, "\(name) \(phase)")
        }
    }
}
