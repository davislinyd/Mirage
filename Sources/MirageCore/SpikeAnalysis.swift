/// 單一階段（延遲比較階段則是單一相機設定）的量測結果。
public struct PhaseReport: Sendable {
    public let phase: Phase
    /// 延遲比較階段的相機設定代號。
    public let config: String?
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
    /// 靜止時游標逐幀位移（螢幕 pt）的 p50 / p95。
    public var jitterRaw: (p50: Double, p95: Double)?
    public var jitterFiltered: (p50: Double, p95: Double)?
    /// 濾波後游標落後原始位置的時間。
    public var filterLagMs: Double?
    public var clickCount = 0
    public var wakeCount = 0
    public var pinchRatioP5: Double?
    public var pinchRatioP95: Double?

    public init(phase: Phase, config: String? = nil) {
        self.phase = phase
        self.config = config
    }
}

public enum SpikeAnalysis {
    /// 切換相機設定後略過的秒數：曝光與擷取管線需要時間穩定。
    static let settle = 2.0

    /// 依錄製順序重跑濾波與偵測器（與即時畫面相同邏輯），再逐階段彙整；延遲比較階段依相機設定分開彙整。
    public static func report(frames: [FrameRecord], mapper: ScreenMapper) -> [PhaseReport] {
        var probe = GestureProbe(mapper: mapper)
        var groups: [[Sample]] = []
        for frame in frames {
            let sample = Sample(frame: frame, result: probe.update(frame))
            if let last = groups.last?.last?.frame, last.phase == frame.phase, last.config == frame.config {
                groups[groups.count - 1].append(sample)
            } else {
                groups.append([sample])
            }
        }
        return groups.map { summarize($0) }
    }

    struct Sample {
        let frame: FrameRecord
        let result: ProbeResult
    }

    /// `group` 為同一階段、同一相機設定的連續樣本，至少一個。
    static func summarize(_ group: [Sample]) -> PhaseReport {
        let phase = group[0].frame.phase
        var report = PhaseReport(phase: phase, config: group[0].frame.config)
        let samples = phase == .latency ? group.filter { $0.frame.t >= group[0].frame.t + settle } : group
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

        report.clickCount = samples.filter { $0.result.clicked }.count
        report.wakeCount = samples.filter { $0.result.woke }.count
        let ratios = samples.compactMap { $0.result.pinchRatio }
        report.pinchRatioP5 = percentile(ratios, 0.05)
        report.pinchRatioP95 = percentile(ratios, 0.95)

        switch phase {
        case .still:
            // 第 1 秒讓手就定位，不計入。
            let settled = detected.filter { $0.frame.t >= first.frame.t + 1 }
            report.jitterRaw = steps(settled.compactMap { $0.result.raw })
            report.jitterFiltered = steps(settled.compactMap { $0.result.filtered })
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

    /// 相鄰兩點距離（逐幀位移）的 p50 / p95。只量幀與幀之間的跳動，手本身緩慢漂移不算抖動。
    static func steps(_ points: [Vec2]) -> (p50: Double, p95: Double)? {
        let distances = zip(points, points.dropFirst()).map { $0.distance(to: $1) }
        guard let p50 = percentile(distances, 0.5), let p95 = percentile(distances, 0.95) else { return nil }
        return (p50, p95)
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
