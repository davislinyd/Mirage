@preconcurrency import AVFoundation
@preconcurrency import Vision
import MirageCore

/// 相機擷取與 Vision 手部偵測。所有可變狀態只在 `queue` 上存取，因此標記為 @unchecked Sendable。
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

    /// 延遲比較階段依序使用的相機設定。
    private struct CameraConfig {
        let label: String
        let format: AVCaptureDevice.Format
        let range: AVFrameRateRange
        let maxHands: Int
    }

    private typealias Candidate = (format: AVCaptureDevice.Format, range: AVFrameRateRange, size: CMVideoDimensions)

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "mirage.capture", qos: .userInteractive)
    /// 切換相機格式時擷取管線會重新設定，不在影格回呼裡等它。
    private let configQueue = DispatchQueue(label: "mirage.camera-config")
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
    private var configs: [CameraConfig] = []
    private var activeConfig = 0
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
        // 延遲比較：A 是正式設定，B 降低解析度，C 只偵測一隻手，D 重測 A，檢查延遲是否隨時間漂移。
        let small = formats.filter { $0.size.width == 640 }.max { $0.range.maxFrameRate < $1.range.maxFrameRate } ?? best
        func config(_ letter: String, _ choice: Candidate, hands: Int, note: String = "") -> CameraConfig {
            CameraConfig(
                label: "\(letter) \(choice.size.width)×\(choice.size.height)・最多 \(hands) 手\(note)",
                format: choice.format, range: choice.range, maxHands: hands
            )
        }
        configs = [
            config("A", best, hands: 2), config("B", small, hands: 2), config("C", best, hands: 1),
            config("D", best, hands: 2, note: "（重測 A）"),
        ]
        request.maximumHandCount = configs[activeConfig].maxHands

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
        // 保持鎖定到停止：鎖定期間 session 不會以預設 preset 覆蓋上面設定的格式與幀率，執行中也才能切換格式。
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

    /// 停止擷取，回傳所有紀錄與丟幀數。
    func stop() -> (frames: [FrameRecord], dropped: Int) {
        session.stopRunning()
        let device = self.device
        // 等進行中的格式切換完成再解鎖；未鎖定時設定格式會丟出例外。
        configQueue.sync { device?.unlockForConfiguration() }
        return queue.sync { (frames, dropped) }
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
        apply(configIndex(phase: phase, remaining: remaining))

        let begin = ProcessInfo.processInfo.systemUptime
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])
        let inferenceMs = (ProcessInfo.processInfo.systemUptime - begin) * 1000
        let latencyMs = (CMClockGetTime(clock).seconds - t) * 1000

        let frame = FrameRecord(
            t: t,
            phase: phase,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            latencyMs: latencyMs,
            inferenceMs: inferenceMs,
            hands: (request.results ?? []).compactMap { hand(from: $0) },
            config: phase == .latency ? configs[activeConfig].label : nil
        )
        frames.append(frame)
        let result = probe.update(frame)
        if startTime == nil {
            handSince = result.raw == nil ? nil : handSince ?? t
            if let handSince, t - handSince >= 1 { startTime = t }
        }
        emit(.frame(snapshot(frame, result: result, remaining: remaining)))
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dropped += 1
    }

    /// 延遲比較階段依時間輪流使用各設定，其餘階段用 A。
    private func configIndex(phase: Phase, remaining: Double?) -> Int {
        guard phase == .latency, let remaining else { return 0 }
        let slot = phase.duration / Double(configs.count)
        return min(configs.count - 1, Int((phase.duration - remaining) / slot))
    }

    private func apply(_ index: Int) {
        guard index != activeConfig, let device else { return }
        let previous = configs[activeConfig]
        let next = configs[index]
        activeConfig = index
        request.maximumHandCount = next.maxHands
        guard next.format != previous.format else { return }
        let format = next.format
        let range = next.range
        configQueue.async {
            device.activeFormat = format
            device.activeVideoMinFrameDuration = range.minFrameDuration
            device.activeVideoMaxFrameDuration = range.minFrameDuration
        }
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
