@preconcurrency import AVFoundation
import CoreGraphics
@preconcurrency import Vision
import MirageCore

/// 相機 → Vision → 校準或游標控制 → CGEvent。可變狀態只在 `queue` 上存取；推論在 `workQueue`，由 `busy` 保證
/// 同時只有一個，忙碌時只保留最新一幀（M0.2 的非同步推論）。因此標記為 @unchecked Sendable。
final class HandTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case state(ControlState)
        case calibration(CalibrationSession.Progress)
    }

    enum TrackerError: Error, CustomStringConvertible {
        case noCamera, configuration

        var description: String {
            switch self {
            case .noCamera: "找不到相機"
            case .configuration: "無法設定相機擷取"
            }
        }
    }

    private enum Mode {
        /// 尚未校準，不處理影像。
        case waiting
        case calibrating(CalibrationSession)
        case controlling(CursorController)
    }

    /// 一幀待推論的影像。推論完成前沒有人會改寫這個 pixel buffer。
    private struct Pending: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let t: Double
    }

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
    /// 主螢幕在 CGEvent 全域座標（原點為主螢幕左上，單位 pt）中的範圍。
    private let screen = CGDisplayBounds(CGMainDisplayID())
    private let sink: @MainActor @Sendable (Event) -> Void

    private var device: AVCaptureDevice?
    private var format: (format: AVCaptureDevice.Format, frameDuration: CMTime)?
    private var running = false
    private var busy = false
    private var waiting: Pending?
    private var mode = Mode.waiting
    private var state = ControlState.idle
    /// 已送出左鍵按下、還沒送出放開。
    private var pressed = false

    init(sink: @escaping @MainActor @Sendable (Event) -> Void) {
        self.sink = sink
        super.init()
        request.maximumHandCount = 2
    }

    /// 選相機與格式並設定擷取。須先取得相機權限。
    func configure() throws {
        // 人物置中會移動裁切範圍，手的座標跟著跳。其他視訊效果只能由使用者從選單列的 Video 選單關閉。
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
        let builtIn = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
        ).devices.first
        guard let device = builtIn ?? AVCaptureDevice.default(for: .video) else { throw TrackerError.noCamera }

        // 同 M0：優先最高幀率（延遲下限由幀間隔決定），其次在 1280 寬以內取最大解析度。
        let formats = device.formats.compactMap { format -> (format: AVCaptureDevice.Format, range: AVFrameRateRange, width: Int32)? in
            guard let range = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return nil }
            return (format, range, CMVideoFormatDescriptionGetDimensions(format.formatDescription).width)
        }
        let preferred = formats.filter { $0.width <= 1280 }
        guard let best = (preferred.isEmpty ? formats : preferred).max(by: {
            ($0.range.maxFrameRate, $0.width) < ($1.range.maxFrameRate, $1.width)
        }) else { throw TrackerError.configuration }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw TrackerError.configuration }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw TrackerError.configuration }
        session.addOutput(output)
        self.device = device
        format = (best.format, best.range.minFrameDuration)
    }

    /// 開始或停止擷取。停止時丟棄進行中的推論結果並回到 Idle，之後須重新喚醒。
    func setRunning(_ running: Bool) {
        queue.async { [self] in
            guard running != self.running, let device, let format else { return }
            if running {
                // 鎖定到停止：鎖定期間 session 不會以預設 preset 覆蓋格式與幀率（同 M0）。
                do { try device.lockForConfiguration() } catch { return }
                device.activeFormat = format.format
                device.activeVideoMinFrameDuration = format.frameDuration
                device.activeVideoMaxFrameDuration = format.frameDuration
                session.startRunning()
            } else {
                session.stopRunning()
                device.unlockForConfiguration()
                waiting = nil
                release()
                if case .controlling(var controller) = mode {
                    controller.deactivate()
                    mode = .controlling(controller)
                }
                publish(.idle)
            }
            self.running = running
        }
    }

    /// 開始校準；完成後改用新的校準結果控制游標。
    func calibrate() {
        queue.async { [self] in
            release()
            mode = .calibrating(CalibrationSession())
            publish(.idle)
        }
    }

    /// 用校準結果控制游標；nil 表示尚未校準，不處理影像。
    func use(_ calibration: Calibration?) {
        queue.async { [self] in
            mode = calibration.map { Mode.controlling(controller(for: $0)) } ?? .waiting
            publish(.idle)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pending = Pending(pixelBuffer: pixelBuffer, t: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
        if busy {
            waiting = pending
        } else {
            detect(pending)
        }
    }

    private func detect(_ pending: Pending) {
        busy = true
        workQueue.async { [self] in
            let handler = VNImageRequestHandler(cvPixelBuffer: pending.pixelBuffer, orientation: .up, options: [:])
            try? handler.perform([request])
            let hands = (request.results ?? []).compactMap { hand(from: $0) }
            queue.async { [self] in
                busy = false
                guard running else { return }
                process(
                    hands, width: CVPixelBufferGetWidth(pending.pixelBuffer),
                    height: CVPixelBufferGetHeight(pending.pixelBuffer), t: pending.t
                )
                if let next = waiting {
                    waiting = nil
                    detect(next)
                }
            }
        }
    }

    private func process(_ hands: [Hand], width: Int, height: Int, t: Double) {
        switch mode {
        case .waiting:
            break
        case .calibrating(var calibration):
            let progress = calibration.update(hands: hands, width: width, height: height, at: t)
            if case .done(let result) = progress {
                mode = .controlling(controller(for: result))
            } else {
                mode = .calibrating(calibration)
            }
            emit(.calibration(progress))
        case .controlling(var controller):
            let output = controller.update(hands: hands, width: width, height: height, at: t)
            mode = .controlling(controller)
            if output.state != .active { release() }
            if let cursor = output.cursor {
                post(output.button, at: cursor)
                if output.rightClick { rightClick(at: cursor) }
            }
            if let scroll = output.scroll { send(scroll: scroll) }
            publish(output.state)
        }
    }

    private func controller(for calibration: Calibration) -> CursorController {
        CursorController(calibration: calibration, screenWidth: screen.width, screenHeight: screen.height)
    }

    /// 按著左鍵時移動要送拖曳事件。
    private func post(_ button: PinchClicker.Button?, at cursor: Vec2) {
        let type: CGEventType = switch button {
        case .down: .leftMouseDown
        case .up: .leftMouseUp
        case nil: pressed ? .leftMouseDragged : .mouseMoved
        }
        send(type, at: point(cursor))
    }

    /// 右鍵按下後立刻放開：選單在按下時打開，放開後保持打開。
    private func rightClick(at cursor: Vec2) {
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point(cursor), mouseButton: .right)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            event?.post(tap: .cghidEventTap)
        }
    }

    /// 游標（主螢幕 pt，原點左下）→ CGEvent 全域座標（原點左上）。
    private func point(_ cursor: Vec2) -> CGPoint {
        CGPoint(x: screen.minX + cursor.x, y: screen.maxY - cursor.y)
    }

    /// 停止控制時放開還按著的左鍵，否則系統會當作左鍵一直按著。
    private func release() {
        guard pressed, let location = CGEvent(source: nil)?.location else { return }
        send(.leftMouseUp, at: location)
    }

    /// 需要輔助使用權限，沒有時系統會直接丟棄事件。
    private func send(_ type: CGEventType, at point: CGPoint) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        if type == .leftMouseDown || type == .leftMouseUp {
            // 標明單擊：點擊次數為 0 的按鍵事件，有些 App 不當作點擊。
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            pressed = type == .leftMouseDown
        }
        event?.post(tap: .cghidEventTap)
    }

    /// 像素單位的連續捲動，同觸控板。內容往上等於滾輪往下，所以正負相反。
    private func send(scroll: Double) {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-scroll), wheel2: 0, wheel3: 0)
        event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event?.post(tap: .cghidEventTap)
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

    /// 狀態改變時通知主執行緒。
    private func publish(_ state: ControlState) {
        guard state != self.state else { return }
        self.state = state
        emit(.state(state))
    }

    private func emit(_ event: Event) {
        let sink = self.sink
        DispatchQueue.main.async {
            MainActor.assumeIsolated { sink(event) }
        }
    }
}
