import CoreImage
import Foundation
import ImageIO
import MirageCore

/// `gaze --frames`：把相機影像存成 JPEG，離線比較不同的注視模型時不必重錄。影像只存本機 `recordings/`（不進版控）。
/// 寫檔在自己的佇列，不占用手與臉的推論；上一張還沒寫完就略過這一張，不長時間持有相機的 pixel buffer。
/// 所有可變狀態由 `lock` 保護，因此標記為 @unchecked Sendable。
final class FrameStore: @unchecked Sendable {
    /// 兩張影像最短相隔秒數；相機 30 fps 時每 3 幀一張，約 10 Hz。
    static let interval = 0.09

    private struct Job: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let url: URL
    }

    let stamp: String
    private let frames: URL
    private let queue = DispatchQueue(label: "mirage.frames", qos: .utility)
    private let slot = DispatchSemaphore(value: 1)
    private let context = CIContext()
    private let lock = NSLock()
    private var written = 0
    private var failed = 0
    private var skipped = 0

    /// 影像放在 `recordings/<腳本>-<時間>/frames/`，同名的 JSONL 放在 `recordings/`。
    init(script: Script) throws {
        stamp = Summary.stamp()
        frames = Summary.directory.appending(path: "\(script.name)-\(stamp)/frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
    }

    /// 排入寫檔並回傳相對於 `recordings/<腳本>-<時間>/` 的路徑；上一張還沒寫完時回傳 nil。
    func save(_ pixelBuffer: CVPixelBuffer, index: Int) -> String? {
        guard slot.wait(timeout: .now()) == .success else {
            lock.withLock { skipped += 1 }
            return nil
        }
        let name = String(format: "%06d.jpg", index)
        let job = Job(pixelBuffer: pixelBuffer, url: frames.appending(path: name))
        queue.async { [self] in
            let image = CIImage(cvPixelBuffer: job.pixelBuffer)
            let data = CGColorSpace(name: CGColorSpace.sRGB).flatMap { space in
                context.jpegRepresentation(
                    of: image, colorSpace: space,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95]
                )
            }
            let ok = (try? data?.write(to: job.url)) != nil
            lock.withLock { if ok { written += 1 } else { failed += 1 } }
            slot.signal()
        }
        return "frames/\(name)"
    }

    /// 等佇列裡的寫檔完成，回傳給摘要的說明。
    func finish() -> String {
        queue.sync {}
        return lock.withLock { "影像：存了 \(written) 張、寫檔失敗 \(failed) 張、略過 \(skipped) 張（上一張還沒寫完）" }
    }
}
