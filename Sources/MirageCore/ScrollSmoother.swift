import Foundation

/// 把相機每幀（約 30 fps、間隔不均）算出的捲動距離，平均分到螢幕每次更新送出：每次送出還沒送的
/// 1 − e^(−dt/`smoothing`)。直接照相機的節奏送，每 30–40 ms 才送一次，偶爾隔 100 ms 以上，高速時一次捲幾十到上百 pt，
/// 內容會一格一格跳。
public struct ScrollSmoother: Sendable {
    /// 秒：約一個相機幀的間隔。越大越平順，但越晚跟上。
    public var smoothing = 0.04
    private var pending = 0.0
    /// 已經分出、不足 1 pt 還沒送的距離。
    private var remainder = 0.0

    public init() {}

    /// 剩下不到 1 pt：可以停止定時送出。
    public var isIdle: Bool { abs(pending + remainder) < 1 }

    /// 加入相機這一幀算出的捲動距離（pt）。
    public mutating func add(_ scroll: Double) {
        pending += scroll
    }

    /// 距離上次送出經過 `dt` 秒：回傳這次要送的整數 pt，沒有時為 nil。
    public mutating func step(_ dt: Double) -> Double? {
        let part = pending * (1 - exp(-dt / smoothing))
        pending -= part
        remainder += part
        let whole = remainder.rounded(.towardZero)
        remainder -= whole
        return whole == 0 ? nil : whole
    }
}
