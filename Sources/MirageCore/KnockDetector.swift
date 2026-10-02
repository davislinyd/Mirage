import Foundation

/// 在掌托上敲兩下（像敲門）。訊號是加速度計去掉重力（每軸指數低通，時間常數 `smoothing`）後的動態量 m（g）：
/// - 衝擊：m 達到 `impact`；之後 `ring` 秒內的餘振不算新衝擊。
/// - 第一下之前 `quietBefore` 秒內 m 都低於 `quiet`：擋搬動電腦、開合螢幕等連續晃動。低於 `quiet` 不到 `bridge` 秒
///   的空檔不算安靜：輕敲時手指先碰到機身，衝擊前 20 ms 有一個 0.02–0.04 g 的小起伏，中間只安靜幾毫秒。
/// - 第二下在第一下之後 `minGap`–`maxGap` 秒；落在 `ring`–`minGap` 之間就整組作廢。
/// - 第二下之後 `settle` 秒內沒有新衝擊才確認：擋連敲。
/// - 確認後 `cooldown` 秒不偵測。
/// 按鍵與點按的時間由呼叫端用 `inputGuard` 檢查：錄影中它們幾乎沒有衝擊，留著是因為快速打字或用力點按時加速度計分不出來。
///
/// 錄影（`mirage-spike knock`）：
/// - 右側掌托一般力道每下 0.11–0.15 g，輕敲 0.06–0.13 g；左側 0.11–0.35 g。兩下間隔：一般 0.24–0.33 秒，輕敲 0.215–0.26 秒。
/// - `impact` 取 0.05 g。0.04 g 時，第一份錄影的準備階段有一次 0.041 與 0.047 g 的兩下（不確定是不是順手敲的）。
/// - 每下的餘振 150 ms 後最高是峰值的 0.3 倍，170 ms 後 0.23 倍。`ring` 取 0.15 秒：0.12 秒時用力敲的餘振會被當成新衝擊。
/// - `minGap` 取 0.19 秒，有兩個作用：
///   - 擋用力敲一下拖長的餘振。
///   - 擋 `ring` 剛結束時還沒衰減完的另一次衝擊。第二份錄影開頭有一次 0.07 g 的兩下，間隔 0.17 秒。
/// - 打字最高 0.026 g；觸控板點按的觸覺回饋幾乎沒有衝擊。手放上掌托會有一串 0.05–0.23 g、間隔約 0.15 秒的衝擊。
/// - 開合螢幕、拿起電腦會連續晃動到 2 g 以上。
/// - 敲桌子兩下和敲掌托一樣大，分不出來。
/// - 振動頻率低（約 25 Hz），降到 200 Hz 取樣峰值幾乎不變。
public struct KnockDetector: Sendable {
    /// 秒。
    public var smoothing = 0.25
    /// g。
    public var impact = 0.05
    public var ring = 0.15
    public var quietBefore = 0.3
    /// g。
    public var quiet = 0.02
    public var bridge = 0.03
    public var minGap = 0.19
    public var maxGap = 0.5
    public var settle = 0.3
    /// 第一下之前這麼多秒內有按鍵或點按，就不算。
    public var inputGuard = 0.5
    public var cooldown = 1.0

    private var gravity: (x: Double, y: Double, z: Double)?
    private var lastT = 0.0
    /// 最近一次 m ≥ `quiet` 的時間。
    private var lastNoisy = -Double.infinity
    /// 目前（或最近）這段晃動開始之前安靜了幾秒。
    private var calm = 0.0
    private var lastImpact = -Double.infinity
    private var first: Double?
    private var second: Double?
    private var resumeAt = -Double.infinity

    public init() {}

    /// 輸入一個樣本（秒、g）。確認敲兩下時回傳第一下的時間。
    public mutating func update(t: Double, x: Double, y: Double, z: Double) -> Double? {
        guard let g = gravity else {
            gravity = (x, y, z)
            lastT = t
            return nil
        }
        let m = ((x - g.x) * (x - g.x) + (y - g.y) * (y - g.y) + (z - g.z) * (z - g.z)).squareRoot()
        let alpha = 1 - exp(-(t - lastT) / smoothing)
        gravity = (g.x + alpha * (x - g.x), g.y + alpha * (y - g.y), g.z + alpha * (z - g.z))
        lastT = t

        if m >= quiet {
            if t - lastNoisy > bridge { calm = t - lastNoisy }
            lastNoisy = t
        }
        let hit = m >= impact && t - lastImpact > ring
        if hit { lastImpact = t }

        if let second {
            if hit {
                reset()
            } else if t - second >= settle {
                let result = first
                reset()
                resumeAt = t + cooldown
                return result
            }
            return nil
        }
        if let first, t - first <= maxGap {
            if hit {
                if t - first >= minGap {
                    second = t
                } else {
                    reset()
                }
            }
            return nil
        }
        first = nil
        if hit, t >= resumeAt, calm >= quietBefore {
            first = t
        }
        return nil
    }

    /// `first`：`update` 回傳的第一下時間；`lastInput`：最近一次按鍵或點按的時間。
    public func accepts(first: Double, lastInput: Double) -> Bool {
        lastInput < first - inputGuard
    }

    private mutating func reset() {
        first = nil
        second = nil
    }
}

/// `mirage-spike knock` 的階段。
public enum KnockPhase: String, Codable, CaseIterable, Sendable {
    /// 階段之間的說明與倒數。
    case prep
    case still, double, single, typing, trackpad, desk, lid, doubleLeft
}

/// 會讓機身震動、要用 `KnockDetector.inputGuard` 擋掉的輸入。
public enum KnockInput: String, Codable, Sendable {
    case key
    /// 觸控板或滑鼠的左右鍵按下、放開。
    case mouseDown, mouseUp
}

/// `mirage-spike knock` 錄影的一行：一個加速度計樣本、一次輸入（`input`），或一次提示（`prompt`）。
public struct KnockRecord: Codable, Sendable {
    /// 秒，`ProcessInfo.systemUptime` 時鐘。
    public var t: Double
    public var phase: KnockPhase
    /// g。
    public var x: Double?
    public var y: Double?
    public var z: Double?
    public var input: KnockInput?
    /// 提示敲擊的時間點（`double`、`single`、`desk`、`doubleLeft` 階段），重播時用來對應觸發。
    public var prompt: Bool?

    public init(
        t: Double, phase: KnockPhase, x: Double? = nil, y: Double? = nil, z: Double? = nil, input: KnockInput? = nil,
        prompt: Bool? = nil
    ) {
        self.t = t
        self.phase = phase
        self.x = x
        self.y = y
        self.z = z
        self.input = input
        self.prompt = prompt
    }
}
