import CoreGraphics
import Foundation
import MirageCore
import Synchronization

/// `mirage-spike knock [--check]`：錄加速度計、按鍵與點按，供 `KnockDetector` 調參；只用終端機，不開相機。`--check` 只讀 2 秒，
/// 印出取樣率與靜止時的加速度後結束。
enum KnockRecorder {
    /// 錄影用硬體最快的回報間隔（µs，約 800 Hz）；App 用的取樣率由降頻重播決定。
    private static let interval: Int32 = 1000
    private static let reading = 5.0
    private static let countdown = 3
    /// 有提示的階段：每 `promptEvery` 秒提示一次，共 `prompts` 次。
    private static let promptEvery = 3.0
    private static let prompts = 10
    /// 按鍵與點按用輪詢偵測（不需要權限），間隔秒數。
    private static let inputPoll = 0.05
    private static let inputs: [(KnockInput, [CGEventType])] = [
        (.key, [.keyDown]), (.mouseDown, [.leftMouseDown, .rightMouseDown]), (.mouseUp, [.leftMouseUp, .rightMouseUp]),
    ]

    private struct Step {
        let phase: KnockPhase
        let instruction: String
        /// nil 表示有提示的階段，長度是 `prompts × promptEvery`。
        let duration: Double?
    }

    private static let steps = [
        Step(phase: .still, instruction: "雙手離開電腦，不要碰桌子", duration: 10),
        Step(phase: .double, instruction: "看到「敲」就用指尖在觸控板右邊的掌托敲兩下（像敲門），力道照你之後想用的", duration: nil),
        Step(phase: .single, instruction: "看到「敲」就在觸控板右邊的掌托只敲一下（不是兩下）", duration: nil),
        Step(phase: .typing, instruction: "切到備忘錄或任何可以打字的地方正常打字；時間到會響一聲，再切回來", duration: 30),
        Step(phase: .trackpad, instruction: "正常用觸控板：移動、點按、捲動、拖曳，手掌自然放在掌托上", duration: 30),
        Step(phase: .desk, instruction: "看到「敲」就只敲一下桌子（不是兩下），或把杯子放到桌上；不要碰電腦", duration: nil),
        Step(phase: .lid, instruction: "把螢幕往後推再拉回來、把電腦拿起一點再放下，重複做", duration: 20),
        Step(phase: .doubleLeft, instruction: "看到「敲」就在觸控板左邊的掌托敲兩下", duration: nil),
    ]

    private struct State {
        var phase = KnockPhase.prep
        var records: [KnockRecord] = []
        /// 各種輸入最近一次的時間；還沒輪詢過時沒有值。
        var lastInput: [KnockInput: Double] = [:]
        var lastPoll = 0.0
    }

    static func run(check: Bool) -> Never {
        let state = Mutex(State())
        let accelerometer = Accelerometer(interval: interval) { t, x, y, z in
            state.withLock { state in
                state.records.append(KnockRecord(t: t, phase: state.phase, x: x, y: y, z: z))
                guard t - state.lastPoll >= inputPoll else { return }
                state.lastPoll = t
                // 用現在而不是樣本時間：樣本成批送達，樣本時間比現在晚得不一定，同一次輸入會被算成好幾次。
                let now = ProcessInfo.processInfo.systemUptime
                for (input, types) in inputs {
                    let at = now - types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min()!
                    // 第一次輪詢只記下開始前的時間，不算一次輸入。
                    if let last = state.lastInput[input], at > last + 0.01 {
                        state.records.append(KnockRecord(t: at, phase: state.phase, input: input))
                    }
                    state.lastInput[input] = at
                }
            }
        }
        do {
            try accelerometer.start()
        } catch {
            print("加速度計無法使用：\(error)")
            exit(1)
        }

        if check {
            Thread.sleep(forTimeInterval: 2)
            accelerometer.stop()
            let (samples, lastKey) = state.withLock { state in (state.records.filter { $0.x != nil }, state.lastInput[.key] ?? 0) }
            guard let first = samples.first, let last = samples.last, samples.count > 1 else {
                print("2 秒內沒有收到資料")
                exit(1)
            }
            let magnitudes = samples.map { sample in
                let (x, y, z) = (sample.x ?? 0, sample.y ?? 0, sample.z ?? 0)
                return (x * x + y * y + z * z).squareRoot()
            }
            print(String(format: "%d 個樣本，%.0f Hz", samples.count, Double(samples.count - 1) / (last.t - first.t)))
            print(String(format: "|a| 平均 %.3f g，範圍 %.3f–%.3f g", magnitudes.reduce(0, +) / Double(magnitudes.count), magnitudes.min()!, magnitudes.max()!))
            print(String(format: "最後一個樣本比現在早 %.3f 秒；上次按鍵在 %.1f 秒前", ProcessInfo.processInfo.systemUptime - last.t, last.t - lastKey))
            exit(0)
        }

        let total = steps.reduce(0) { $0 + reading + Double(countdown) + ($1.duration ?? Double(prompts) * promptEvery) }
        print("共 \(steps.count) 個階段，約 \(Int(total / 60) + 1) 分鐘。照提示做即可；按 ⌃C 放棄（不存檔）。")
        for (index, step) in steps.enumerated() {
            state.withLock { $0.phase = .prep }
            print("\n[\(index + 1)/\(steps.count)] \(step.instruction)")
            Thread.sleep(forTimeInterval: reading)
            for n in stride(from: countdown, to: 0, by: -1) {
                print("\(n)…", terminator: " ")
                fflush(stdout)
                Thread.sleep(forTimeInterval: 1)
            }
            print("開始")
            state.withLock { $0.phase = step.phase }
            if let duration = step.duration {
                Thread.sleep(forTimeInterval: duration)
                print("\u{7}時間到")
            } else {
                for n in 1...prompts {
                    Thread.sleep(forTimeInterval: n == 1 ? 1 : promptEvery)
                    let t = ProcessInfo.processInfo.systemUptime
                    state.withLock { $0.records.append(KnockRecord(t: t, phase: step.phase, prompt: true)) }
                    print("\u{7}敲（\(n)/\(prompts)）")
                }
                Thread.sleep(forTimeInterval: promptEvery - 1)
            }
        }
        accelerometer.stop()
        // 打字階段如果打在終端機，丟掉這些輸入，免得結束後被 shell 執行。
        tcflush(STDIN_FILENO, TCIFLUSH)

        let records = state.withLock { $0.records }.sorted { $0.t < $1.t }
        do {
            let url = try save(records)
            let samples = records.filter { $0.x != nil }.count
            let keys = records.filter { $0.input == .key }.count
            let clicks = records.filter { $0.input == .mouseDown }.count
            print("\n已存 \(url.path)：\(samples) 個樣本、\(keys) 次按鍵、\(clicks) 次點按")
        } catch {
            print("存檔失敗：\(error)")
            exit(1)
        }
        exit(0)
    }

    private static func save(_ records: [KnockRecord]) throws -> URL {
        try FileManager.default.createDirectory(at: Summary.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        let url = Summary.directory.appending(path: "knock-\(Summary.stamp()).jsonl")
        try data.write(to: url)
        return url
    }
}
