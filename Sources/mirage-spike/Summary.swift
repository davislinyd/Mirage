import Foundation
import MirageCore

enum Summary {
    static func text(
        script: Script, camera: String, dropped: Int, skipped: Int, reports: [PhaseReport], gaze: GazeReport?,
        depth: [DepthAnalysis.FeatureReport]?
    ) -> String {
        let pinch = PinchDetector()
        var lines = [
            "", "===== Mirage \(script.name) 結果 =====", camera,
            "丟幀：\(dropped)（同步推論來不及，被相機丟棄的影格）",
            "略過：\(skipped)（非同步推論忙碌時，被較新影格取代的影格）",
        ]
        for report in reports where report.phase != .warmup {
            lines.append("")
            lines.append("[\(report.phase.title)\(report.config.map { " \($0)" } ?? "")] \(report.frames) 幀・\(number(report.fps)) fps・偵測率 \(percent(report.detectionRate))・判定為右手 \(percent(report.rightHandRate))")
            lines.append("  延遲 p50/p95：\(number(report.latencyP50)) / \(number(report.latencyP95)) ms（其中送達 \(number(report.deliveryP50)) / \(number(report.deliveryP95))、推論 \(number(report.inferenceP50)) / \(number(report.inferenceP95)) ms）")
            switch report.phase {
            case .still:
                lines.append("  逐幀跳動 p50/p95（螢幕 pt）：原始 \(number(report.jitterRaw?.p50)) / \(number(report.jitterRaw?.p95)) → 濾波後 \(number(report.jitterFiltered?.p50)) / \(number(report.jitterFiltered?.p95))")
            case .move:
                lines.append("  濾波延遲：\(number(report.filterLagMs)) ms")
            case .pinch:
                lines.append("  點擊 \(report.clickCount) 次（應為 10）・捏合比例 p5/p95：\(number(report.pinchRatioP5, digits: 2)) / \(number(report.pinchRatioP95, digits: 2))（閾值 \(pinch.enterRatio) / \(pinch.exitRatio)）")
            case .wake:
                lines.append("  喚醒 \(report.wakeCount) 次（應為 5）")
            case .daily:
                lines.append("  誤觸：點擊 \(report.clickCount) 次、喚醒 \(report.wakeCount) 次")
            default:
                break
            }
        }
        if let gaze {
            lines.append("")
            lines.append("[注視估計] 量得到兩眼與瞳孔 \(percent(gaze.usableRate))・臉部偵測 p50/p95：\(number(gaze.faceMsP50)) / \(number(gaze.faceMsP95)) ms")
            lines.append("  誤差 p50/p90（pt）；「平滑」為最近 0.3 秒的中位數。通過標準：p50 ≤ 100、p90 ≤ 200")
            func error(_ e: GazeError?) -> String { e.map { "\(number($0.p50, digits: 0)) / \(number($0.p90, digits: 0))" } ?? "—" }
            for model in gaze.models {
                lines.append("  \(model.name)：驗證 \(error(model.check))（平滑 \(error(model.checkSmoothed))、10 Hz \(error(model.check10Hz)))・轉頭 \(error(model.head))（平滑 \(error(model.headSmoothed)))・留一 \(error(model.leaveOneOut))")
            }
        }
        if let depth {
            lines.append("")
            lines.append("[深度估計] 0.3 秒內的上升量：懸停 p99｜按鍵、往前戳取上升最多的 10 下中位數（括號為 ÷ 懸停 p99，≥ 3 算分得開）｜快速移動、日常 p99")
            for row in depth {
                let digits = [.flex2D, .bend3D].contains(row.feature) ? 1 : 3
                func ratio(_ value: Double?) -> String {
                    guard let value, let hover = row.hover, hover > 0 else { return "" }
                    return "（\(number(value / hover))×）"
                }
                lines.append("  \(row.feature.title)：\(number(row.hover, digits: digits))｜\(number(row.tap, digits: digits))\(ratio(row.tap))、\(number(row.push, digits: digits))\(ratio(row.push))｜\(number(row.sweep, digits: digits))、\(number(row.daily, digits: digits))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 把每幀紀錄（JSONL）與摘要存到 `recordings/`，檔名以腳本名稱開頭，回傳 JSONL 路徑。
    static func save(frames: [FrameRecord], summary: String, script: Script) throws -> URL {
        let directory = URL.currentDirectory().appending(path: "recordings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let encoder = JSONEncoder()
        var data = Data()
        for frame in frames {
            data.append(try encoder.encode(frame))
            data.append(0x0A)
        }
        let url = directory.appending(path: "\(script.name)-\(stamp).jsonl")
        try data.write(to: url)
        try Data(summary.utf8).write(to: directory.appending(path: "\(script.name)-\(stamp).txt"))
        return url
    }

    private static func number(_ value: Double?, digits: Int = 1) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(digits)f", value)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
