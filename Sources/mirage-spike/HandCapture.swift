@preconcurrency import AVFoundation
@preconcurrency import Vision
import MirageCore

/// 相機擷取與 Vision 手部偵測。所有可變狀態只在 `queue` 上存取；非同步推論時 `request` 與待推論影像交給
/// `workQueue`，由 `busy` 保證同一時間只有一個推論。因此標記為 @unchecked Sendable。
final class HandCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case frame(SkeletonSnapshot)
        case phase(Phase)
        case finished
    }

    enum CaptureError: Error, CustomStringConvertible {
        case noCamera, noFormat, configuration

        var description: String {
            switch self {
            case .noCamera: "找不到相機"
            case .noFormat: "相機沒有可用的影像格式"
            case .configuration: "無法設定相機擷取"
            }
        }
    }

    /// 一幀待推論的影像與它在擷取當下決定的階段資訊。推論完成前沒有人會改寫這個 pixel buffer。
    private struct Pending: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let t: Double
        let deliveryMs: Double
        let phase: Phase
        let remaining: Double?
        let config: String?
    }

    private typealias Detection = (hands: [Hand], inferenceMs: Double, latencyMs: Double)
    private typealias Candidate = (format: AVCaptureDevice.Format, range: AVFrameRateRange, size: CMVideoDimensions)

    /// 延遲比較階段依序使用的處理方式。同步：在影格回呼裡等推論完成（M0 的做法），推論偶爾變慢時，
    /// 後面的影格會一直晚一到兩幀送達。非同步：回呼立刻返回，推論在 `workQueue` 進行，忙碌時只保留最新一幀。
    private let modes: [(label: String, inline: Bool)] = [
        ("A 同步", true), ("B 非同步", false), ("C 同步（重測 A）", true), ("D 非同步（重測 B）", false),
    ]

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "mirage.capture", qos: .userInteractive)
    private let workQueue = DispatchQueue(label: "mirage.vision", qos: .userInteractive)
    private let request = VNDetectHumanHandPoseRequest()
    private let jointNames: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]
    private let mapper: ScreenMapper
    private let sink: @MainActor @Sendable (Event) -> Void

    private var device: AVCaptureDevice?
    /// 非同步推論進行中。
    private var busy = false
    /// 推論忙碌時收到的最新一幀，較舊的直接略過。
    private var waiting: Pending?
    private var skipped = 0
    private var clock = CMClockGetHostTimeClock()
    private var probe: GestureProbe
    private var frames: [FrameRecord] = []
    private var handSince: Double?
    private var startTime: Double?
    private var lastPhase: Phase?
    private var finished = false
    private var dropped = 0
    private var recentTimes: [Double] = []
    private var recentLatencies: [Double] = []

    init(mapper: ScreenMapper, sink: @escaping @MainActor @Sendable (Event) -> Void) {
        self.mapper = mapper
        self.sink = sink
        probe = GestureProbe(mapper: mapper)
        super.init()
        request.maximumHandCount = 2
    }

    /// 設定並啟動相機，回傳所選裝置、格式與視訊效果的說明。
    func start() throws -> String {
        let effects = Self.disableVideoEffects()
        let builtIn = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
        ).devices.first
        guard let device = builtIn ?? AVCaptureDevice.default(for: .video) else { throw CaptureError.noCamera }
        self.device = device

        // 優先最高幀率（延遲下限由幀間隔決定），其次在 1280 寬以內取最大解析度；手部模型不需要更高解析度。
        let formats = device.formats.compactMap { format -> Candidate? in
            guard let range = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return nil }
            return (format, range, CMVideoFormatDescriptionGetDimensions(format.formatDescription))
        }
        let preferred = formats.filter { $0.size.width <= 1280 }
        guard let best = (preferred.isEmpty ? formats : preferred).max(by: {
            ($0.range.maxFrameRate, $0.size.width) < ($1.range.maxFrameRate, $1.size.width)
        }) else { throw CaptureError.noFormat }

        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.configuration }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        // 推論來不及時直接丟掉舊影格，永遠處理最新的一幀，避免延遲累積。
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.configuration }
        session.addOutput(output)
        session.commitConfiguration()

        try device.lockForConfiguration()
        device.activeFormat = best.format
        device.activeVideoMinFrameDuration = best.range.minFrameDuration
        device.activeVideoMaxFrameDuration = best.range.minFrameDuration
        // 保持鎖定到停止：鎖定期間 session 不會以預設 preset 覆蓋上面設定的格式與幀率。
        queue.async { [self] in
            session.startRunning()
            clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        }

        let available = Set(formats.map { "\($0.size.width)×\($0.size.height)@\(Int($0.range.maxFrameRate.rounded()))" }).sorted()
        return """
        相機：\(device.localizedName)
        使用格式：\(best.size.width)×\(best.size.height) @ \(Int(best.range.maxFrameRate.rounded())) fps
        可用格式：\(available.joined(separator: "、"))
        \(effects)
        """
    }

    /// 停止擷取，回傳所有紀錄、丟幀數與推論忙碌時略過的幀數。
    func stop() -> (frames: [FrameRecord], dropped: Int, skipped: Int) {
        session.stopRunning()
        device?.unlockForConfiguration()
        return queue.sync { (frames, dropped, skipped) }
    }

    /// 系統視訊效果（控制中心 → 視訊效果）會在影像交給 App 前加工，可能增加延遲；人物置中還會移動裁切範圍，
    /// 讓手的座標跟著跳。人物置中可由 App 接管並關閉，其他效果只能由使用者關閉。
    private static func disableVideoEffects() -> String {
        let effects = [
            ("人物置中", AVCaptureDevice.isCenterStageEnabled),
            ("人像", AVCaptureDevice.isPortraitEffectEnabled),
            ("攝影棚燈光", AVCaptureDevice.isStudioLightEnabled),
            ("背景", AVCaptureDevice.isBackgroundReplacementEnabled),
            ("反應", AVCaptureDevice.reactionEffectsEnabled),
            ("反應手勢", AVCaptureDevice.reactionEffectGesturesEnabled),
        ]
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
        var lines = [
            "視訊效果（啟動前）：" + effects.map { "\($0.0) \($0.1 ? "開" : "關")" }.joined(separator: "、"),
            "人物置中：" + (AVCaptureDevice.isCenterStageEnabled ? "無法關閉" : "已由本工具關閉"),
        ]
        let userControlled = effects.dropFirst().filter { $0.1 }.map { $0.0 }
        if !userControlled.isEmpty {
            lines.append("建議先到控制中心 → 視訊效果關閉：\(userControlled.joined(separator: "、"))，再重新執行")
        }
        return lines.joined(separator: "\n")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finished, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let deliveryMs = (CMClockGetTime(clock).seconds - t) * 1000

        // 手連續入鏡 1 秒後才開始計時，在那之前都是準備階段。
        var phase = Phase.warmup
        var remaining: Double?
        if let startTime {
            guard let current = Phase.at(elapsed: t - startTime) else {
                finished = true
                emit(.finished)
                return
            }
            phase = current.phase
            remaining = current.remaining
        }
        if phase != lastPhase {
            lastPhase = phase
            emit(.phase(phase))
        }

        let latencyMode = mode(phase: phase, remaining: remaining)
        let pending = Pending(
            pixelBuffer: pixelBuffer, t: t, deliveryMs: deliveryMs, phase: phase, remaining: remaining,
            config: latencyMode?.label
        )
        if busy {
            if waiting != nil { skipped += 1 }
            waiting = pending
        } else if latencyMode?.inline == true {
            finish(pending, detect(pending))
        } else {
            startDetection(pending)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dropped += 1
    }

    /// 延遲比較階段依時間輪流使用各處理方式；其餘階段為 nil，用非同步。
    private func mode(phase: Phase, remaining: Double?) -> (label: String, inline: Bool)? {
        guard phase == .latency, let remaining else { return nil }
        let slot = phase.duration / Double(modes.count)
        return modes[min(modes.count - 1, Int((phase.duration - remaining) / slot))]
    }

    private func startDetection(_ pending: Pending) {
        busy = true
        workQueue.async { [self] in
            let detection = detect(pending)
            queue.async { [self] in
                busy = false
                finish(pending, detection)
                if let next = waiting, !finished {
                    waiting = nil
                    startDetection(next)
                }
            }
        }
    }

    private func detect(_ pending: Pending) -> Detection {
        let begin = ProcessInfo.processInfo.systemUptime
        let handler = VNImageRequestHandler(cvPixelBuffer: pending.pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])
        let inferenceMs = (ProcessInfo.processInfo.systemUptime - begin) * 1000
        let latencyMs = (CMClockGetTime(clock).seconds - pending.t) * 1000
        return ((request.results ?? []).compactMap { hand(from: $0) }, inferenceMs, latencyMs)
    }

    private func finish(_ pending: Pending, _ detection: Detection) {
        guard !finished else { return }
        let frame = FrameRecord(
            t: pending.t,
            phase: pending.phase,
            width: CVPixelBufferGetWidth(pending.pixelBuffer),
            height: CVPixelBufferGetHeight(pending.pixelBuffer),
            latencyMs: detection.latencyMs,
            inferenceMs: detection.inferenceMs,
            hands: detection.hands,
            config: pending.config,
            deliveryMs: pending.deliveryMs
        )
        frames.append(frame)
        let result = probe.update(frame)
        if startTime == nil {
            handSince = result.raw == nil ? nil : handSince ?? frame.t
            if let handSince, frame.t - handSince >= 1 { startTime = frame.t }
        }
        emit(.frame(snapshot(frame, result: result, remaining: pending.remaining)))
    }

    private func hand(from observation: VNHumanHandPoseObservation) -> Hand? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        let joints = jointNames.map { name in
            points[name].map { JointSample(x: $0.location.x, y: $0.location.y, c: Double($0.confidence)) }
                ?? JointSample(x: 0, y: 0, c: 0)
        }
        let chirality: MirageCore.Chirality = switch observation.chirality {
        case .left: .left
        case .right: .right
        default: .unknown
        }
        return Hand(chirality: chirality, joints: joints)
    }

    private func snapshot(_ frame: FrameRecord, result: ProbeResult, remaining: Double?) -> SkeletonSnapshot {
        recentTimes.append(frame.t)
        recentLatencies.append(frame.latencyMs)
        if recentTimes.count > 30 {
            recentTimes.removeFirst()
            recentLatencies.removeFirst()
        }
        let span = (recentTimes.last ?? 0) - (recentTimes.first ?? 0)
        return SkeletonSnapshot(
            hands: frame.hands.map { hand in
                let geometry = HandGeometry(hand: hand, width: frame.width, height: frame.height)
                return Joint.allCases.map { joint in
                    geometry.normalized(joint).map { point in Vec2(x: 1 - point.x, y: point.y) }
                }
            },
            primary: frame.primaryHand.flatMap { frame.hands.firstIndex(of: $0) },
            cursor: result.filtered.map { mapper.mirroredNormalized(fromScreen: $0) },
            pinched: result.isPinched,
            phase: frame.phase,
            remaining: remaining,
            fps: span > 0 ? Double(recentTimes.count - 1) / span : 0,
            latencyMs: recentLatencies.reduce(0, +) / Double(recentLatencies.count)
        )
    }

    private func emit(_ event: Event) {
        let sink = self.sink
        DispatchQueue.main.async {
            MainActor.assumeIsolated { sink(event) }
        }
    }
}
