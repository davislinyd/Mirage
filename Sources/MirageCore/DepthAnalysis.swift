import Foundation

/// 只用 Vision 的 2D 關節推估深度（2.5D），評估加入深度能不能讓按鍵更好分辨。
///
/// - 食指近端一節（指根→PIP）與指尖兩節（PIP→指尖）在 `move` 階段的長度（掌寬單位）取 95 百分位，當作平貼畫面時的
///   真實長度；某一幀量到的比它短，就是轉出畫面，出平面角 = acos(長度比)。
/// - 3D 彎曲估計：兩段各自補上出平面的分量再算夾角。單一畫面分不出往鏡頭還是往反方向轉，這裡假設兩段都往鏡頭那側：
///   手心朝鏡頭時，彎手指就是往鏡頭彎。
/// - 整手靠近：掌寬 ÷ 校準掌寬 − 1。手在鏡頭前約 30 cm，往螢幕推 1.5 cm 掌寬約大 5%。
public enum DepthAnalysis {
    public enum Feature: CaseIterable, Sendable {
        case flex2D, bend3D, shortening, approach

        public var title: String {
            switch self {
            case .flex2D: "2D 彎曲（度）"
            case .bend3D: "3D 彎曲估計（度）"
            case .shortening: "指尖兩節前縮（比例）"
            case .approach: "整手靠近（比例）"
            }
        }
    }

    /// 平貼畫面時的長度（掌寬單位）。
    public struct Lengths: Sendable {
        public var proximal: Double
        public var distal: Double

        public init(proximal: Double, distal: Double) {
            self.proximal = proximal
            self.distal = distal
        }
    }

    /// 某個特徵在 0.3 秒內的上升量（同 `TapDetector` 的彎曲量上升）。
    public struct FeatureReport: Sendable {
        public let feature: Feature
        /// 懸停時的 p99：雜訊。
        public var hover: Double?
        /// 按鍵、往前戳各取上升最多的 10 下（相隔至少 0.5 秒）的中位數：訊號。
        public var tap: Double?
        public var push: Double?
        /// 快速移動、日常的 p99：可能的誤觸。
        public var sweep: Double?
        public var daily: Double?
    }

    static let window = 0.3

    /// `palm`：校準掌寬（像素）。
    public static func features(_ hand: Hand, width: Int, height: Int, lengths: Lengths, palm: Double) -> [Feature: Double]? {
        let geometry = HandGeometry(hand: hand, width: width, height: height)
        guard let w = geometry.palmWidth, w > 0, let flex = geometry.indexFlex, let m = geometry.pixel(.indexMCP),
              let p = geometry.pixel(.indexPIP), let t = geometry.pixel(.indexTip),
              m.distance(to: p) > 0, p.distance(to: t) > 0 else { return nil }
        func direction(_ a: Vec2, _ b: Vec2, _ length: Double) -> (x: Double, y: Double, z: Double) {
            let shown = a.distance(to: b)
            let ratio = min(1, shown / w / length)
            return ((b.x - a.x) / shown * ratio, (b.y - a.y) / shown * ratio, (1 - ratio * ratio).squareRoot())
        }
        let u = direction(m, p, lengths.proximal)
        let v = direction(p, t, lengths.distal)
        let cosine = max(-1, min(1, u.x * v.x + u.y * v.y + u.z * v.z))
        return [
            .flex2D: flex,
            .bend3D: acos(cosine) * 180 / .pi,
            .shortening: 1 - min(1, p.distance(to: t) / w / lengths.distal),
            .approach: w / palm - 1,
        ]
    }

    /// 用 `move` 階段校準，彙整各特徵在懸停、按鍵、往前戳、快速移動、日常的上升量；沒有 `move` 階段時為 nil。
    public static func report(frames: [FrameRecord]) -> [FeatureReport]? {
        var proximal: [Double] = []
        var distal: [Double] = []
        var palms: [Double] = []
        for frame in frames where frame.phase == .move {
            guard let hand = frame.hands.primary else { continue }
            let geometry = HandGeometry(hand: hand, width: frame.width, height: frame.height)
            guard let w = geometry.palmWidth, geometry.isPointing(palmWidth: w) == true, let m = geometry.pixel(.indexMCP),
                  let p = geometry.pixel(.indexPIP), let t = geometry.pixel(.indexTip) else { continue }
            proximal.append(m.distance(to: p) / w)
            distal.append(p.distance(to: t) / w)
            palms.append(w)
        }
        let percentile = SpikeAnalysis.percentile
        guard let lp = percentile(proximal, 0.95), let ld = percentile(distal, 0.95), let palm = percentile(palms, 0.5) else { return nil }
        let lengths = Lengths(proximal: lp, distal: ld)

        /// 姿勢正確（同 `TapDetector`：食指尖仍高於指根）的每一幀，各特徵比最近 `window` 秒內最小值高出多少。
        func rises(_ phase: Phase) -> [(t: Double, rise: [Feature: Double])] {
            var history: [(t: Double, values: [Feature: Double])] = []
            var rises: [(t: Double, rise: [Feature: Double])] = []
            for frame in frames where frame.phase == phase {
                guard let hand = frame.hands.primary else { continue }
                let geometry = HandGeometry(hand: hand, width: frame.width, height: frame.height)
                guard let w = geometry.palmWidth, geometry.isPointing(palmWidth: w, up: 0.2) == true,
                      let values = features(hand, width: frame.width, height: frame.height, lengths: lengths, palm: palm)
                else { continue }
                history.removeAll { frame.t - $0.t > window }
                history.append((frame.t, values))
                var rise: [Feature: Double] = [:]
                for feature in Feature.allCases {
                    let low = history.compactMap { $0.values[feature] }.min() ?? 0
                    rise[feature] = (values[feature] ?? low) - low
                }
                rises.append((frame.t, rise))
            }
            return rises
        }

        let series = Dictionary(uniqueKeysWithValues: [Phase.hover, .tap, .push, .sweep, .daily].map { ($0, rises($0)) })
        return Feature.allCases.map { feature in
            func values(_ phase: Phase) -> [(t: Double, value: Double)] {
                (series[phase] ?? []).compactMap { sample in sample.rise[feature].map { (sample.t, $0) } }
            }
            var report = FeatureReport(feature: feature)
            report.hover = percentile(values(.hover).map(\.value), 0.99)
            report.tap = percentile(peaks(values(.tap)), 0.5)
            report.push = percentile(peaks(values(.push)), 0.5)
            report.sweep = percentile(values(.sweep).map(\.value), 0.99)
            report.daily = percentile(values(.daily).map(\.value), 0.99)
            return report
        }
    }

    /// 由大到小挑出最多 `count` 個相隔至少 `gap` 秒的值。
    static func peaks(_ values: [(t: Double, value: Double)], count: Int = 10, gap: Double = 0.5) -> [Double] {
        var picked: [(t: Double, value: Double)] = []
        for candidate in values.sorted(by: { $0.value > $1.value }) where picked.count < count {
            if picked.allSatisfy({ abs($0.t - candidate.t) >= gap }) { picked.append(candidate) }
        }
        return picked.map(\.value)
    }
}
