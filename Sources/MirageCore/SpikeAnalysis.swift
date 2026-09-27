/// 單一階段的量測結果。
public struct PhaseReport: Sendable {
    public let phase: Phase
    public var frames = 0
    public var fps = 0.0
    /// 偵測到主要手食指尖的幀比例。
    public var detectionRate = 0.0
    /// 偵測到的幀中，Vision 判定為右手的比例。
    public var rightHandRate = 0.0
    public var latencyP50 = 0.0
    public var latencyP95 = 0.0
    public var inferenceP50 = 0.0
    public var inferenceP95 = 0.0
    /// 靜止時游標位置到質心的均方根距離（螢幕 pt）。
    public var jitterRaw: Double?
    public var jitterFiltered: Double?
    /// 濾波後游標落後原始位置的時間。
    public var filterLagMs: Double?
    public var pinchCount = 0
    public var wakeCount = 0
    public var pinchRatioP5: Double?
    public var pinchRatioP95: Double?

    public init(phase: Phase) {
        self.phase = phase
    }
}

public enum SpikeAnalysis {
    /// 依錄製順序重跑濾波與偵測器（與即時畫面相同邏輯），再逐階段彙整。
    public static func report(frames: [FrameRecord], mapper: ScreenMapper) -> [PhaseReport] {
        var probe = GestureProbe(mapper: mapper)
        var samples: [Phase: [Sample]] = [:]
        for frame in frames {
            samples[frame.phase, default: []].append(Sample(frame: frame, result: probe.update(frame)))
        }
        return Phase.allCases.compactMap { phase in
            samples[phase].map { summarize(phase, $0) }
        }
    }

    struct Sample {
        let frame: FrameRecord
        let result: ProbeResult
    }

    static func summarize(_ phase: Phase, _ samples: [Sample]) -> PhaseReport {
        var report = PhaseReport(phase: phase)
        report.frames = samples.count
        guard let first = samples.first, let last = samples.last else { return report }
        let span = last.frame.t - first.frame.t
        if span > 0 { report.fps = Double(samples.count - 1) / span }

        let detected = samples.filter { $0.result.raw != nil }
        report.detectionRate = Double(detected.count) / Double(samples.count)
        if !detected.isEmpty {
            report.rightHandRate = Double(detected.filter { $0.result.isRight }.count) / Double(detected.count)
        }

        let latencies = samples.map { $0.frame.latencyMs }
        let inferences = samples.map { $0.frame.inferenceMs }
        report.latencyP50 = percentile(latencies, 0.5) ?? 0
        report.latencyP95 = percentile(latencies, 0.95) ?? 0
        report.inferenceP50 = percentile(inferences, 0.5) ?? 0
        report.inferenceP95 = percentile(inferences, 0.95) ?? 0

        report.pinchCount = samples.filter { $0.result.pinchStarted }.count
        report.wakeCount = samples.filter { $0.result.woke }.count
        let ratios = samples.compactMap { $0.result.pinchRatio }
        report.pinchRatioP5 = percentile(ratios, 0.05)
        report.pinchRatioP95 = percentile(ratios, 0.95)

        switch phase {
        case .still:
            // 第 1 秒讓手就定位，不計入。
            let settled = detected.filter { $0.frame.t >= first.frame.t + 1 }
            report.jitterRaw = spread(settled.compactMap { $0.result.raw })
            report.jitterFiltered = spread(settled.compactMap { $0.result.filtered })
        case .move where detected.count > 1:
            let interval = (detected[detected.count - 1].frame.t - detected[0].frame.t) / Double(detected.count - 1)
            report.filterLagMs = lagMs(
                raw: detected.compactMap { $0.result.raw },
                filtered: detected.compactMap { $0.result.filtered },
                interval: interval
            )
        default:
            break
        }
        return report
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[Int((Double(sorted.count - 1) * p).rounded())]
    }

    /// 各點到質心的均方根距離。
    static func spread(_ points: [Vec2]) -> Double? {
        guard points.count > 1 else { return nil }
        let n = Double(points.count)
        let center = Vec2(x: points.reduce(0) { $0 + $1.x } / n, y: points.reduce(0) { $0 + $1.y } / n)
        return (points.reduce(0) { $0 + $1.squaredDistance(to: center) } / n).squareRoot()
    }

    /// 找出讓濾波序列與原始序列最吻合的位移幀數（拋物線內插到次幀精度），換算成毫秒。
    static func lagMs(raw: [Vec2], filtered: [Vec2], interval: Double) -> Double? {
        guard raw.count == filtered.count, raw.count > 30 else { return nil }
        let shifts = Array(-2...10)
        let errors = shifts.map { shift -> Double in
            let range = max(0, shift)..<min(raw.count, raw.count + shift)
            let sum = range.reduce(0.0) { $0 + filtered[$1].squaredDistance(to: raw[$1 - shift]) }
            return sum / Double(range.count)
        }
        guard let best = errors.indices.min(by: { errors[$0] < errors[$1] }) else { return nil }
        var shift = Double(shifts[best])
        if best > 0, best < errors.count - 1 {
            let (a, b, c) = (errors[best - 1], errors[best], errors[best + 1])
            let curvature = a - 2 * b + c
            if curvature > 0 { shift += 0.5 * (a - c) / curvature }
        }
        return max(0, shift) * interval * 1000
    }
}
