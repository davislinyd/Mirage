/// 分辨手指懸空的顫抖與真正的移動。位置以校準掌寬為單位計算，與校準範圍的大小（游標的放大倍率）無關。
///
/// 兩份錄影（手放低、1:1 畫面）中，對準十字懸停時 PIP 相對 0.5 秒平均的偏離 p95 約 0.045 掌寬；以校準範圍換算，
/// 1 掌寬約等於 800–1100 pt，所以顫抖會變成 30–50 pt 的游標晃動。懸停時的瞬間速度（p95 1.2 掌寬／秒）比刻意慢慢
/// 對準（p95 0.6）還快，只看速度分不開，所以用一段時間的淨位移判斷：顫抖來回晃，淨位移小。
///
/// - 靜止：最近 `speedWindow` 秒的淨速度低於 `stillSpeed` 持續 `stillTime` 秒，游標停住；手離開停住的位置超過
///   `holdRadius` 才恢復移動，停住期間的位移不算進去。
/// - 慢速縮小倍率（PRISM，Frees & Kessler 2007）：淨速度低於 `precisionSpeed` 時，游標的位移乘上
///   速度 ÷ `precisionSpeed`，最少 `minGain`，方便對準小目標。錄影中慢速對準的速度 p95 約 0.6 掌寬／秒。
/// - 收回偏差：上面兩項會讓游標和手指的絕對對應產生偏差；淨速度超過 `recoverSpeed` 時，每幀收回
///   `recoverRate` × 速度 ÷ `recoverSpeed`（最多全部），快速移動後游標回到手指對應的位置，螢幕邊緣仍然到得了；
///   慢速時不收，免得干擾對準。
public struct PointerStabilizer: Sendable {
    public var holdRadius = 0.04
    public var stillSpeed = 0.15
    public var stillTime = 0.15
    public var speedWindow = 0.2
    public var precisionSpeed = 0.8
    public var minGain = 0.3
    public var recoverSpeed = 1.5
    public var recoverRate = 0.2
    /// 秒：看不到手超過此時間，重新從手指的位置開始。
    public var resetGap = 0.2

    /// 目前停住的位置；移動中為 nil。
    public private(set) var anchor: Vec2?
    /// 輸出位置（掌寬單位）。
    private var output: Vec2?
    private var previous: (point: Vec2, t: Double)?
    private var recent: [(point: Vec2, t: Double)] = []
    /// 淨速度低於 `stillSpeed` 的開始時間。
    private var slowSince: Double?

    public init() {}

    /// `point`：游標基準點（正規化影像座標）；`scale`：校準掌寬（像素）。回傳要對應到螢幕的點（正規化影像座標）。
    public mutating func update(_ point: Vec2, width: Int, height: Int, scale: Double, at t: Double) -> Vec2 {
        let p = Vec2(x: point.x * Double(width) / scale, y: point.y * Double(height) / scale)
        if let previous, t - previous.t > resetGap { reset() }
        recent.removeAll { t - $0.t > speedWindow }
        recent.append((p, t))
        var speed = 0.0
        if let first = recent.first, t > first.t { speed = first.point.distance(to: p) / (t - first.t) }
        var out = output ?? p
        var from = previous?.point
        if let anchor {
            let away = p.distance(to: anchor)
            if away > holdRadius {
                // 離開停住的範圍：只扣掉範圍內的位移，超出的部分算進這一幀的移動。
                self.anchor = nil
                slowSince = nil
                from = Vec2(x: anchor.x + (p.x - anchor.x) * holdRadius / away, y: anchor.y + (p.y - anchor.y) * holdRadius / away)
            } else {
                from = nil
            }
        }
        if anchor == nil, let from {
            let gain = min(1, max(minGain, speed / precisionSpeed))
            out = Vec2(x: out.x + (p.x - from.x) * gain, y: out.y + (p.y - from.y) * gain)
            if speed > recoverSpeed {
                let rate = min(1, recoverRate * speed / recoverSpeed)
                out = Vec2(x: out.x + (p.x - out.x) * rate, y: out.y + (p.y - out.y) * rate)
            }
            slowSince = speed < stillSpeed ? (slowSince ?? t) : nil
            if let slowSince, t - slowSince >= stillTime { anchor = p }
        }
        output = out
        previous = (p, t)
        return Vec2(x: out.x * scale / Double(width), y: out.y * scale / Double(height))
    }

    public mutating func reset() {
        anchor = nil
        output = nil
        previous = nil
        recent = []
        slowSince = nil
    }
}
