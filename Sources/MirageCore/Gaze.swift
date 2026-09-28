import Foundation

/// 一張臉的關鍵點，座標為正規化影像座標（0...1，原點左下，未鏡像）。只存座標，不存影像。
public struct Face: Codable, Sendable, Equatable {
    /// 臉框中心與寬高。
    public var center: Vec2
    public var width: Double
    public var height: Double
    /// 頭部角度（弧度）：左右轉、上下點頭、歪頭；量不到時為 nil。
    public var yaw: Double?
    public var pitch: Double?
    public var roll: Double?
    /// 眼睛輪廓（Vision 的 leftEye、rightEye）與瞳孔。
    public var leftEye: [Vec2]
    public var rightEye: [Vec2]
    public var leftPupil: Vec2?
    public var rightPupil: Vec2?

    public init(
        center: Vec2, width: Double, height: Double, yaw: Double?, pitch: Double?, roll: Double?,
        leftEye: [Vec2], rightEye: [Vec2], leftPupil: Vec2?, rightPupil: Vec2?
    ) {
        self.center = center
        self.width = width
        self.height = height
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.leftPupil = leftPupil
        self.rightPupil = rightPupil
    }
}

/// 注視階段的目標：螢幕上 3×3 的點，離邊緣 10%，每 `interval` 秒換一個；三個階段順序不同。
public enum GazeTargets {
    public static let interval = 2.0
    /// 螢幕比例（0...1，原點左下），由上而下、由左而右。
    static let grid: [Vec2] = [0.9, 0.5, 0.1].flatMap { y in [0.1, 0.5, 0.9].map { x in Vec2(x: x, y: y) } }

    static func order(_ phase: Phase) -> [Int]? {
        switch phase {
        case .gazeCalibrate: Array(0..<9)
        case .gazeCheck: [4, 8, 0, 6, 2, 7, 1, 5, 3]
        case .gazeHead: [2, 6, 4, 0, 8, 3, 5, 1, 7]
        default: nil
        }
    }

    /// `phase` 開始後 `elapsed` 秒要看的點（螢幕比例）；不是注視階段時為 nil。
    public static func target(_ phase: Phase, elapsed: Double) -> Vec2? {
        guard let order = order(phase) else { return nil }
        return grid[order[min(order.count - 1, max(0, Int(elapsed / interval)))]]
    }
}

/// 某個模型在各種驗證方式下，逐幀估計位置與目標的距離（螢幕 pt）。
public struct GazeError: Sendable {
    public var p50: Double
    public var p90: Double
}

public struct GazeModelReport: Sendable {
    public let name: String
    /// 用注視校準階段的 9 點擬合，估計注視驗證階段；`smoothed` 為最近 `smoothing` 秒估計值的中位數。
    public var check: GazeError?
    public var checkSmoothed: GazeError?
    /// 同一個擬合，估計轉頭注視階段。
    public var head: GazeError?
    public var headSmoothed: GazeError?
    /// 注視校準階段每次留一個點不擬合、只拿來驗證。
    public var leaveOneOut: GazeError?
    /// 臉部偵測降到 10 Hz（每 3 幀一次）時，注視驗證階段的平滑後誤差。
    public var check10Hz: GazeError?
}

public struct GazeReport: Sendable {
    /// 注視階段量得到兩眼輪廓與瞳孔的幀比例。
    public var usableRate = 0.0
    public var faceMsP50: Double?
    public var faceMsP95: Double?
    public var models: [GazeModelReport] = []
}

/// 用臉部關鍵點估計注視位置：瞳孔在兩個眼角之間的位置（除以眼寬，沿眼角連線與其垂直方向，歪頭時不變），兩眼平均；
/// 再加上頭部角度與臉在畫面中的位置。每位使用者看 9 個點做嶺迴歸。
public enum GazeAnalysis {
    /// 目標換位置後略過的秒數：眼睛移過去、停穩之前不算。
    static let settle = 0.6
    static let smoothing = 0.3
    static let lambda = 1.0

    struct Features: Sendable {
        /// 兩眼平均的瞳孔位置（眼寬單位）。
        var eye: Vec2
        var yaw: Double
        var pitch: Double
        var center: Vec2
    }

    /// 模型名稱與輸入欄位。只看頭的模型當作對照：眼睛的訊號有用，才會比它準。
    static let models: [(name: String, row: @Sendable (Features) -> [Double])] = [
        ("眼睛（二次）", { f in [f.eye.x, f.eye.y, f.eye.x * f.eye.y, f.eye.x * f.eye.x, f.eye.y * f.eye.y] }),
        ("眼睛＋頭（一次）", { f in [f.eye.x, f.eye.y, f.yaw, f.pitch, f.center.x, f.center.y] }),
        ("只看頭（一次）", { f in [f.yaw, f.pitch, f.center.x, f.center.y] }),
    ]

    static func features(_ face: Face, width: Int, height: Int) -> Features? {
        func pixel(_ p: Vec2) -> Vec2 { Vec2(x: p.x * Double(width), y: p.y * Double(height)) }
        func offset(_ contour: [Vec2], _ pupil: Vec2?) -> Vec2? {
            guard let pupil, contour.count >= 2 else { return nil }
            let points = contour.map(pixel)
            // 眼角：輪廓上距離最遠的兩點。
            var corners = (points[0], points[1])
            var span = 0.0
            for i in points.indices {
                for j in points.indices where j > i && points[i].distance(to: points[j]) > span {
                    span = points[i].distance(to: points[j])
                    corners = (points[i], points[j])
                }
            }
            guard span > 0 else { return nil }
            let (a, b) = corners.0.x <= corners.1.x ? corners : (corners.1, corners.0)
            let u = Vec2(x: (b.x - a.x) / span, y: (b.y - a.y) / span)
            let p = pixel(pupil)
            let d = Vec2(x: p.x - (a.x + b.x) / 2, y: p.y - (a.y + b.y) / 2)
            return Vec2(x: (d.x * u.x + d.y * u.y) / span, y: (d.y * u.x - d.x * u.y) / span)
        }
        guard let left = offset(face.leftEye, face.leftPupil), let right = offset(face.rightEye, face.rightPupil) else { return nil }
        return Features(
            eye: Vec2(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2),
            yaw: face.yaw ?? 0, pitch: face.pitch ?? 0, center: face.center
        )
    }

    struct Sample {
        var t: Double
        var target: Vec2
        var features: Features
    }

    /// 各注視階段中，目標停穩 `settle` 秒後、量得到特徵的幀。
    static func samples(_ frames: [FrameRecord], phase: Phase) -> [Sample] {
        var samples: [Sample] = []
        var since: (target: Vec2, t: Double)?
        for frame in frames where frame.phase == phase {
            guard let target = frame.target else { continue }
            if since?.target != target { since = (target, frame.t) }
            guard let since, frame.t - since.t >= settle, let face = frame.face,
                  let features = features(face, width: frame.width, height: frame.height) else { continue }
            samples.append(Sample(t: frame.t, target: target, features: features))
        }
        return samples
    }

    public static func report(frames: [FrameRecord]) -> GazeReport {
        var report = GazeReport()
        let gazeFrames = frames.filter { [.gazeCalibrate, .gazeCheck, .gazeHead].contains($0.phase) }
        if !gazeFrames.isEmpty {
            let usable = gazeFrames.filter { frame in frame.face.flatMap { features($0, width: frame.width, height: frame.height) } != nil }
            report.usableRate = Double(usable.count) / Double(gazeFrames.count)
        }
        let faceMs = frames.compactMap(\.faceMs)
        report.faceMsP50 = SpikeAnalysis.percentile(faceMs, 0.5)
        report.faceMsP95 = SpikeAnalysis.percentile(faceMs, 0.95)

        let calibration = samples(frames, phase: .gazeCalibrate)
        let check = samples(frames, phase: .gazeCheck)
        let head = samples(frames, phase: .gazeHead)
        for model in models {
            var result = GazeModelReport(name: model.name)
            if let fit = Ridge(calibration.map { model.row($0.features) }, calibration.map(\.target)) {
                let predict = { (s: Sample) in fit.predict(model.row(s.features)) }
                result.check = error(check, predict)
                result.checkSmoothed = error(check, predict, smoothed: true)
                result.head = error(head, predict)
                result.headSmoothed = error(head, predict, smoothed: true)
                let tenHz = check.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
                result.check10Hz = error(tenHz, predict, smoothed: true)
            }
            var distances: [Double] = []
            for target in Set(calibration.map { "\($0.target.x),\($0.target.y)" }) {
                let held = calibration.filter { "\($0.target.x),\($0.target.y)" == target }
                let rest = calibration.filter { "\($0.target.x),\($0.target.y)" != target }
                guard let fit = Ridge(rest.map { model.row($0.features) }, rest.map(\.target)) else { continue }
                distances += held.map { fit.predict(model.row($0.features)).distance(to: $0.target) }
            }
            result.leaveOneOut = summary(distances)
            report.models.append(result)
        }
        return report
    }

    /// `smoothed`：改用同一個目標、最近 `smoothing` 秒內估計值的中位數（x、y 分開取），眨眼等單幀錯誤不影響。
    static func error(_ samples: [Sample], _ predict: (Sample) -> Vec2, smoothed: Bool = false) -> GazeError? {
        let predictions = samples.map(predict)
        let distances = samples.indices.map { i -> Double in
            guard smoothed else { return predictions[i].distance(to: samples[i].target) }
            let window = samples.indices.filter { j in
                j <= i && samples[j].target == samples[i].target && samples[i].t - samples[j].t <= smoothing
            }
            let x = SpikeAnalysis.percentile(window.map { predictions[$0].x }, 0.5) ?? 0
            let y = SpikeAnalysis.percentile(window.map { predictions[$0].y }, 0.5) ?? 0
            return Vec2(x: x, y: y).distance(to: samples[i].target)
        }
        return summary(distances)
    }

    static func summary(_ distances: [Double]) -> GazeError? {
        guard let p50 = SpikeAnalysis.percentile(distances, 0.5), let p90 = SpikeAnalysis.percentile(distances, 0.9) else { return nil }
        return GazeError(p50: p50, p90: p90)
    }
}

/// 嶺迴歸：各欄先標準化，截距不懲罰，x、y 分開擬合。
struct Ridge {
    private var mean: [Double]
    private var scale: [Double]
    private var wx: [Double]
    private var wy: [Double]

    init?(_ rows: [[Double]], _ targets: [Vec2], lambda: Double = GazeAnalysis.lambda) {
        guard let columns = rows.first?.count, rows.count > columns + 1 else { return nil }
        let n = Double(rows.count)
        mean = (0..<columns).map { c in rows.reduce(0) { $0 + $1[c] } / n }
        scale = (0..<columns).map { [mean] c in
            let variance = rows.reduce(0) { $0 + ($1[c] - mean[c]) * ($1[c] - mean[c]) } / n
            return variance > 0 ? variance.squareRoot() : 1
        }
        let design = rows.map { [mean, scale] row in [1] + (0..<columns).map { (row[$0] - mean[$0]) / scale[$0] } }
        let size = columns + 1
        var normal = [[Double]](repeating: [Double](repeating: 0, count: size), count: size)
        var bx = [Double](repeating: 0, count: size)
        var by = [Double](repeating: 0, count: size)
        for (row, target) in zip(design, targets) {
            for i in 0..<size {
                bx[i] += row[i] * target.x
                by[i] += row[i] * target.y
                for j in 0..<size { normal[i][j] += row[i] * row[j] }
            }
        }
        for i in 1..<size { normal[i][i] += lambda }
        guard let wx = Self.solve(normal, bx), let wy = Self.solve(normal, by) else { return nil }
        self.wx = wx
        self.wy = wy
    }

    func predict(_ row: [Double]) -> Vec2 {
        let x = [1] + row.indices.map { (row[$0] - mean[$0]) / scale[$0] }
        return Vec2(x: zip(x, wx).reduce(0) { $0 + $1.0 * $1.1 }, y: zip(x, wy).reduce(0) { $0 + $1.0 * $1.1 })
    }

    /// 高斯消去法（部分選主元）。
    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = zip(a, b).map { $0 + [$1] }
        let n = b.count
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot)
            for row in 0..<n where row != col {
                let factor = m[row][col] / m[col][col]
                for k in col...n { m[row][k] -= factor * m[col][k] }
            }
        }
        return (0..<n).map { m[$0][n] / m[$0][$0] }
    }
}
