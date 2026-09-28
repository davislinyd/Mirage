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
        /// 畫面上顯示的階段：說明與倒數期間是下一個階段，`phase` 則記錄為準備階段。
        let shown: Phase
        /// 說明與倒數期間，距離開始的秒數。
        let startsIn: Double?
        let config: String?
        /// 這一幀也偵測臉。
        let face: Bool
        /// 注視階段要看的點（螢幕 pt）。
        let target: Vec2?
    }

    private typealias Detection = (hands: [Hand], face: Face?, inferenceMs: Double, faceMs: Double?, latencyMs: Double)
    private typealias Candidate = (format: AVCaptureDevice.Format, range: AVFrameRateRange, size: CMVideoDimensions)

    /// 延遲比較階段依序使用的處理方式。同步：在影格回呼裡等推論完成（M0 的做法），推論偶爾變慢時，
    /// 後面的影格會一直晚一到兩幀送達。非同步：回呼立刻返回，推論在 `workQueue` 進行，忙碌時只保留最新一幀。
    private let modes: [(label: String, inline: Bool)] = [
        ("A 同步", true), ("B 非同步", false), ("C 同步（重測 A）", true), ("D 非同步（重測 B）", false),
    ]
    /// 臉部偵測延遲階段依序使用的處理方式：只偵測手，或同一幀接著偵測臉，比較手的延遲。
    private let faceModes: [(label: String, face: Bool)] = [("只有手", false), ("手＋臉", true), ("只有手", false), ("手＋臉", true)]

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "mirage.capture", qos: .userInteractive)
    private let workQueue = DispatchQueue(label: "mirage.vision", qos: .userInteractive)
    private let request = VNDetectHumanHandPoseRequest()
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private let jointNames: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]
    private let mapper: ScreenMapper
    private let script: Script
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
    /// 手（需要偵測臉的腳本為臉）連續入鏡的開始時間。
    private var readySince: Double?
    private var startTime: Double?
    private var lastPhase: Phase?
    private var finished = false
    private var dropped = 0
    private var recentTimes: [Double] = []
    private var recentLatencies: [Double] = []

    init(mapper: ScreenMapper, script: Script, sink: @escaping @MainActor @Sendable (Event) -> Void) {
        self.mapper = mapper
        self.script = script
        self.sink = sink
        probe = GestureProbe(mapper: mapper)
        super.init()
        request.maximumHandCount = 2
    }

    /// 設定並啟動相機，回傳所選裝置、格式與視訊效果的說明。`size` 指定格式，nil 時同 App。
    func start(size: (width: Int32, height: Int32)?) throws -> String {
        let effects = Self.disableVideoEffects()
        let builtIn = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
        ).devices.first
        guard let device = builtIn ?? AVCaptureDevice.default(for: .video) else { throw CaptureError.noCamera }
        self.device = device

        let formats = device.formats.compactMap { format -> Candidate? in
            guard let range = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return nil }
            return (format, range, CMVideoFormatDescriptionGetDimensions(format.formatDescription))
        }
        // 預設同 App：優先最高幀率（延遲下限由幀間隔決定），其次在寬度 1600 以內、不是直式的格式中取最高的。
        let preferred = formats.filter { candidate in
            size.map { candidate.size.width == $0.width && candidate.size.height == $0.height }
                ?? (candidate.size.width >= candidate.size.height && candidate.size.width <= 1600)
        }
        if size != nil, preferred.isEmpty { throw CaptureError.noFormat }
        guard let best = (preferred.isEmpty ? formats : preferred).max(by: {
            ($0.range.maxFrameRate, $0.size.height, $0.size.width) < ($1.range.maxFrameRate, $1.size.height, $1.size.width)
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

    /// 系統視訊效果（選單列的 Video 選單）會在影像交給 App 前加工，可能增加延遲；人物置中還會移動裁切範圍，
    /// 讓手的座標跟著跳。人物置中可由 App 接管並關閉，其他效果只能由使用者關閉。
    private static func disableVideoEffects() -> String {
        // 不列 `reactionEffectsEnabled`：它只代表 App 能顯示反應效果，macOS 對所有 App 預設開啟、使用者無法關閉；
        // 會不會自動偵測手勢並觸發效果，由 `reactionEffectGesturesEnabled` 決定。
        let effects = [
            ("人物置中", AVCaptureDevice.isCenterStageEnabled),
            ("人像", AVCaptureDevice.isPortraitEffectEnabled),
            ("攝影棚燈光", AVCaptureDevice.isStudioLightEnabled),
            ("背景", AVCaptureDevice.isBackgroundReplacementEnabled),
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
            lines.append("建議趁本工具使用鏡頭時，從選單列的 Video 選單關閉：\(userControlled.joined(separator: "、"))，再重新執行（設定依 App 分開記憶）")
        }
        return lines.joined(separator: "\n")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finished, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let deliveryMs = (CMClockGetTime(clock).seconds - t) * 1000

        // 手（或臉）連續入鏡 1 秒後才開始計時，在那之前都是準備階段；每個階段開始前的說明與倒數也記錄為準備階段。
        var phase = Phase.warmup
        var shown = Phase.warmup
        var remaining: Double?
        var startsIn: Double?
        if let startTime {
            guard let current = script.at(elapsed: t - startTime) else {
                finished = true
                emit(.finished)
                return
            }
            shown = current.phase
            startsIn = current.startsIn
            if startsIn == nil {
                phase = current.phase
                remaining = current.remaining
            }
        }
        if shown != lastPhase {
            lastPhase = shown
            emit(.phase(shown))
        }

        let latencyMode = mode(phase: phase, remaining: remaining)
        let faceMode = faceMode(phase: phase, remaining: remaining)
        let target = remaining.flatMap { GazeTargets.target(phase, elapsed: phase.duration - $0) }
        let pending = Pending(
            pixelBuffer: pixelBuffer, t: t, deliveryMs: deliveryMs, phase: phase, remaining: remaining, shown: shown,
            startsIn: startsIn, config: latencyMode?.label ?? faceMode?.label, face: script.usesFace && faceMode?.face != false,
            target: target.map { Vec2(x: $0.x * mapper.screenWidth, y: $0.y * mapper.screenHeight) }
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

    /// 臉部偵測延遲階段依時間輪流使用各處理方式；其餘階段為 nil。
    private func faceMode(phase: Phase, remaining: Double?) -> (label: String, face: Bool)? {
        guard phase == .faceLatency, let remaining else { return nil }
        let slot = phase.duration / Double(faceModes.count)
        return faceModes[min(faceModes.count - 1, Int((phase.duration - remaining) / slot))]
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
        var face: Face?
        var faceMs: Double?
        if pending.face {
            let faceBegin = ProcessInfo.processInfo.systemUptime
            try? handler.perform([faceRequest])
            faceMs = (ProcessInfo.processInfo.systemUptime - faceBegin) * 1000
            let largest = (faceRequest.results ?? []).max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
            face = largest.flatMap { self.face(from: $0) }
        }
        let latencyMs = (CMClockGetTime(clock).seconds - pending.t) * 1000
        return ((request.results ?? []).compactMap { hand(from: $0) }, face, inferenceMs, faceMs, latencyMs)
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
            deliveryMs: pending.deliveryMs,
            face: detection.face,
            faceMs: detection.faceMs,
            target: pending.target
        )
        frames.append(frame)
        let result = probe.update(frame)
        if startTime == nil {
            let ready = script.usesFace ? frame.face != nil : result.raw != nil
            readySince = ready ? readySince ?? frame.t : nil
            if let readySince, frame.t - readySince >= 1 { startTime = frame.t }
        }
        emit(.frame(snapshot(frame, result: result, pending: pending)))
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

    /// 只取眼睛輪廓與瞳孔，換算成整張影像的正規化座標。
    private func face(from observation: VNFaceObservation) -> Face? {
        guard let landmarks = observation.landmarks else { return nil }
        let box = observation.boundingBox
        func points(_ region: VNFaceLandmarkRegion2D?) -> [Vec2] {
            (region?.normalizedPoints ?? []).map { Vec2(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height) }
        }
        return Face(
            center: Vec2(x: box.midX, y: box.midY), width: box.width, height: box.height,
            yaw: observation.yaw?.doubleValue, pitch: observation.pitch?.doubleValue, roll: observation.roll?.doubleValue,
            leftEye: points(landmarks.leftEye), rightEye: points(landmarks.rightEye),
            leftPupil: points(landmarks.leftPupil).first, rightPupil: points(landmarks.rightPupil).first
        )
    }

    private func snapshot(_ frame: FrameRecord, result: ProbeResult, pending: Pending) -> SkeletonSnapshot {
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
            phase: pending.shown,
            instruction: script.instruction(for: pending.shown),
            remaining: pending.remaining,
            startsIn: pending.startsIn,
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
