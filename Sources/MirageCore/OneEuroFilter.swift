/// One Euro Filter（Casiez et al., CHI 2012）。
/// 截止頻率隨速度調整：慢速時低，濾掉手部生理震顫；快速時升高，減少拖影。
/// 固定 α 的 EMA 只能在「去抖」與「延遲」間二選一，這裡兩者兼顧。
/// 預設參數以螢幕 pt 為單位。
public struct OneEuroFilter: Sendable {
    /// 靜止時的截止頻率（Hz），越低越平滑。
    public var minCutoff: Double
    /// 速度對截止頻率的增益，越高越跟手。
    public var beta: Double
    /// 速度估計本身的截止頻率（Hz）。
    public var derivativeCutoff: Double

    private var previousRaw: Double?
    private var filtered = 0.0
    private var derivative = 0.0
    private var time = 0.0

    public init(minCutoff: Double = 1.0, beta: Double = 0.007, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    public mutating func callAsFunction(_ value: Double, at t: Double) -> Double {
        guard let previousRaw else {
            self.previousRaw = value
            filtered = value
            time = t
            return value
        }
        let dt = t - time
        guard dt > 0 else { return filtered }
        derivative += Self.alpha(cutoff: derivativeCutoff, dt: dt) * ((value - previousRaw) / dt - derivative)
        let cutoff = minCutoff + beta * abs(derivative)
        filtered += Self.alpha(cutoff: cutoff, dt: dt) * (value - filtered)
        self.previousRaw = value
        time = t
        return filtered
    }

    public mutating func reset() {
        previousRaw = nil
        derivative = 0
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// 對 x、y 各自套用 One Euro Filter。
public struct OneEuroFilter2D: Sendable {
    private var x: OneEuroFilter
    private var y: OneEuroFilter

    public init(_ filter: OneEuroFilter = OneEuroFilter()) {
        x = filter
        y = filter
    }

    public mutating func callAsFunction(_ point: Vec2, at t: Double) -> Vec2 {
        let fx = x(point.x, at: t)
        let fy = y(point.y, at: t)
        return Vec2(x: fx, y: fy)
    }

    public mutating func reset() {
        x.reset()
        y.reset()
    }
}
