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

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "mirage.capture", qos: .userInteractive)
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
    private var clock = CMClockGetHostTimeClock()
    private var probe: GestureProbe
    private var frames: [FrameRecord] = []
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

    /// 設定並啟動相機，回傳所選裝置與格式的說明。
    func start() throws -> String {
        let builtIn = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
        ).devices.first
        guard let device = builtIn ?? AVCaptureDevice.default(for: .video) else { throw CaptureError.noCamera }
        self.device = device

        // 優先最高幀率（延遲下限由幀間隔決定），其次在 1280 寬以內取最大解析度；手部模型不需要更高解析度。
        let formats = device.formats.compactMap { format -> (format: AVCaptureDevice.Format, range: AVFrameRateRange, size: CMVideoDimensions)? in
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
        queue.async { [self] in
            session.startRunning()
            // 啟動後才解鎖，否則 session 會以預設 preset 覆蓋上面設定的格式與幀率。
            self.device?.unlockForConfiguration()
            clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        }

        let available = Set(formats.map { "\($0.size.width)×\($0.size.height)@\(Int($0.range.maxFrameRate.rounded()))" }).sorted()
        return """
        相機：\(device.localizedName)
        使用格式：\(best.size.width)×\(best.size.height) @ \(Int(best.range.maxFrameRate.rounded())) fps
        可用格式：\(available.joined(separator: "、"))
        """
    }

    /// 停止擷取，回傳所有紀錄與丟幀數。
    func stop() -> (frames: [FrameRecord], dropped: Int) {
        session.stopRunning()
        return queue.sync { (frames, dropped) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finished, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let begin = ProcessInfo.processInfo.systemUptime
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])
        let inferenceMs = (ProcessInfo.processInfo.systemUptime - begin) * 1000
        let latencyMs = (CMClockGetTime(clock).seconds - t) * 1000

        let startTime = self.startTime ?? t
        self.startTime = startTime
        guard let current = Phase.at(elapsed: t - startTime) else {
            finished = true
            emit(.finished)
            return
        }
        if current.phase != lastPhase {
            lastPhase = current.phase
            emit(.phase(current.phase))
        }

        let frame = FrameRecord(
            t: t,
            phase: current.phase,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            latencyMs: latencyMs,
            inferenceMs: inferenceMs,
            hands: (request.results ?? []).compactMap { hand(from: $0) }
        )
        frames.append(frame)
        emit(.frame(snapshot(frame, remaining: current.remaining)))
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dropped += 1
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

    private func snapshot(_ frame: FrameRecord, remaining: Double) -> SkeletonSnapshot {
        let result = probe.update(frame)
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
