/// 待命（等喚醒手勢）時每 `idleInterval` 秒才處理一幀，約 10 fps；其他狀態每幀都處理。待命時沒有手在操作，喚醒手勢
/// （張手、握拳各停約 0.3 秒）10 fps 就抓得到：三份 m0 錄影的喚醒 8、5、5 次，抽成每 3 幀 1 幀、三種起點都一樣，日常的
/// 誤喚醒也沒變。省下的是手部偵測：待命時鏡頭開著、沒人入鏡，每幀偵測約佔 18–28% 單核 CPU。
public struct FrameThrottle: Sendable {
    public var idleInterval = 0.1
    /// 容許相機幀間隔的抖動：30 fps 時每三幀處理一幀，第三幀離上一次可能只有 0.095 秒。
    public var slack = 0.02
    private var last: Double?

    public init() {}

    /// `t`：這一幀的時間（秒）；`idle`：待命中。回傳 true 表示這一幀要處理。
    public mutating func shouldProcess(at t: Double, idle: Bool) -> Bool {
        if idle, let last, t - last < idleInterval - slack { return false }
        last = t
        return true
    }
}
