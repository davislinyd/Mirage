import Foundation
import Testing
@testable import MirageCore

/// 800 Hz 的合成加速度計：重力 (0, 0, -1) g，`knocks` 的每個時間點有一次衰減振盪（`strength` g、200 Hz、時間常數
/// 10 ms）；`precursor` 時每下之前 22–12 ms 另有一個 0.03 g 的小起伏（輕敲時手指先碰到機身）；`shaking` 期間另有
/// 0.05 g、5 Hz 的晃動。回傳每次確認的第一下時間。
private func run(
    knocks: [Double], strength: Double = 0.3, precursor: Bool = false, shaking: ClosedRange<Double>? = nil, until end: Double = 4,
    detector: KnockDetector = KnockDetector()
) -> [Double] {
    var detector = detector
    var found: [Double] = []
    for i in 0..<Int(end * 800) {
        let t = Double(i) / 800
        var z = -1.0
        for knock in knocks where t >= knock {
            z += strength * exp(-(t - knock) / 0.01) * sin(2 * .pi * 200 * (t - knock))
        }
        for knock in knocks where precursor && (knock - 0.022..<knock - 0.012).contains(t) {
            z += 0.03 * sin(.pi * (t - knock + 0.022) / 0.01)
        }
        if let shaking, shaking.contains(t) {
            z += 0.05 * sin(2 * .pi * 5 * t)
        }
        if let first = detector.update(t: t, x: 0, y: 0, z: z) {
            found.append(first)
        }
    }
    return found
}

@Suite struct KnockDetectorTests {
    @Test func doubleKnockConfirmsAfterSettling() throws {
        let found = run(knocks: [1, 1.25])
        try #require(found.count == 1)
        #expect(abs(found[0] - 1) < 0.01)
    }

    /// 錄影中右側掌托每下 0.11–0.15 g；Davis 想要更輕也能用。0.07 g 的振盪取樣後峰值約 0.062 g。
    @Test func lightKnockCounts() {
        #expect(run(knocks: [1, 1.25], strength: 0.07).count == 1)
    }

    /// 前兆和衝擊之間只短暫安靜，不算第一下之前有晃動。
    @Test func precursorDoesNotCountAsShaking() {
        #expect(run(knocks: [1, 1.25], strength: 0.07, precursor: true).count == 1)
    }

    @Test func singleOrTripleKnockDoesNothing() {
        #expect(run(knocks: [1]).isEmpty)
        #expect(run(knocks: [1, 1.25, 1.5]).isEmpty)
    }

    @Test func gapMustBeInRange() {
        #expect(run(knocks: [1, 1.1]).isEmpty)
        #expect(run(knocks: [1, 1.17]).isEmpty)
        #expect(run(knocks: [1, 1.7]).isEmpty)
    }

    /// 選單的「兩下最長間隔」滑桿改的是 `maxGap`。
    @Test func slowerKnocksWhenMaxGapIsLonger() {
        var detector = KnockDetector()
        detector.maxGap = 0.8
        #expect(run(knocks: [1, 1.7], detector: detector).count == 1)
    }

    @Test func needsQuietBeforeFirstKnock() {
        #expect(run(knocks: [1, 1.25], shaking: 0.5...0.95).isEmpty)
        #expect(run(knocks: [1, 1.25], shaking: 0.2...0.6).count == 1)
    }

    @Test func cooldownSkipsImmediateRepeat() {
        #expect(run(knocks: [1, 1.25, 2, 2.25]).count == 1)
        #expect(run(knocks: [1, 1.25, 3, 3.25]).count == 2)
    }

    @Test func rejectsRecentKeyOrClick() {
        let detector = KnockDetector()
        #expect(detector.accepts(first: 10, lastInput: 9))
        #expect(!detector.accepts(first: 10, lastInput: 9.8))
        #expect(!detector.accepts(first: 10, lastInput: 10.3))
    }
}

/// 用 `recordings/` 的 `mirage-spike knock` 錄影重播 `KnockDetector`，並照 App 的做法檢查最近的按鍵與點按。錄影不進版控，
/// 沒有檔案時略過。
private enum KnockReplay {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../recordings").standardized
    /// 一般力道。「敲一下」與「敲桌子」兩個階段實際上每次都敲了兩下；「敲兩下」的第 6 次沒有敲。
    static let normal = "knock-2026-10-01T10-40-01Z"
    /// 輕敲（「敲兩下」階段）。原本要用來驗證，結果找出輕敲的前兆與 ring 結束時的邊界問題，也參與了調整。
    static let light = "knock-2026-10-01T10-57-20Z"
    static let available = [normal, light].allSatisfy {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0).jsonl").path)
    }

    static func load(_ name: String) throws -> [KnockRecord] {
        let text = try String(contentsOf: directory.appendingPathComponent("\(name).jsonl"), encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map { try decoder.decode(KnockRecord.self, from: Data($0.utf8)) }
    }

    /// 每 `step` 個樣本取一個（錄影約 800 Hz），回傳各階段確認並通過輸入檢查的次數，以及被輸入檢查擋掉的次數。
    static func triggers(_ records: [KnockRecord], step: Int) -> (accepted: [KnockPhase: Int], rejected: Int) {
        var detector = KnockDetector()
        var accepted: [KnockPhase: Int] = [:]
        var rejected = 0
        var lastInput = -Double.infinity
        var index = 0
        for record in records {
            if record.input != nil { lastInput = record.t }
            guard let x = record.x, let y = record.y, let z = record.z else { continue }
            index += 1
            guard index % step == 0, let first = detector.update(t: record.t, x: x, y: y, z: z) else { continue }
            if detector.accepts(first: first, lastInput: lastInput) {
                accepted[record.phase, default: 0] += 1
            } else {
                rejected += 1
            }
        }
        return (accepted, rejected)
    }
}

@Suite(.enabled(if: KnockReplay.available)) struct KnockReplayTests {
    /// 800 Hz（錄影）與 200 Hz（App）：掌托敲兩下都抓到（左右分不出來），打字、觸控板、開合螢幕、靜止都沒有。桌子敲兩下
    /// 也會觸發，不檢查。
    @Test(arguments: [1, 4]) func normalRecording(step: Int) throws {
        var result = KnockReplay.triggers(try KnockReplay.load(KnockReplay.normal), step: step)
        result.accepted[.desk] = nil
        #expect(result.accepted == [.double: 9, .single: 10, .doubleLeft: 10])
        #expect(result.rejected == 0)
    }

    /// 輕敲兩下與左側都抓到；只敲一下、敲桌子一下、打字、觸控板、開合螢幕與準備階段都沒有。
    @Test(arguments: [1, 4]) func lightRecording(step: Int) throws {
        let result = KnockReplay.triggers(try KnockReplay.load(KnockReplay.light), step: step)
        #expect(result.accepted == [.double: 10, .doubleLeft: 10])
        #expect(result.rejected == 0)
    }
}
