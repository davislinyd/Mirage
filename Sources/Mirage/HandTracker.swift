@preconcurrency import AVFoundation
import Carbon.HIToolbox
import CoreGraphics
import OSLog
@preconcurrency import Vision
import MirageCore

/// 相機 → Vision → 校準或游標控制 → CGEvent。可變狀態只在 `queue` 上存取；推論在 `workQueue`，由 `busy` 保證
/// 同時只有一個，忙碌時只保留最新一幀（M0.2 的非同步推論）。因此標記為 @unchecked Sendable。
final class HandTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// 動作紀錄：狀態、點擊、右鍵、捲動模式、送出的捲動與縮放記為 notice（會保存），捲動模式中每幀的食指高度記為 info
    /// （只在記憶體，用 `log stream --level info` 即時看）。
    /// `log show --predicate 'subsystem == "io.github.davislinyd.Mirage"' --last 1h --style compact`
    private static let log = Logger(subsystem: "io.github.davislinyd.Mirage", category: "gesture")

    enum Event: Sendable {
        case state(ControlState)
        /// 捲動開始、結束或換方向。
        case scrolling(Scroller.Direction?)
        /// 控制中的操作模式；不在控制中時為 nil。
        case mode(ControlMode?)
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
    /// `configure()` 選定的影像寬高。
    private(set) var frameSize: (width: Int, height: Int)?
    private var running = false
    private var busy = false
    private var waiting: Pending?
    private var mode = Mode.waiting
    private var state = ControlState.idle
    private var scrolling: Scroller.Direction?
    private var controlMode: ControlMode?
    /// 已送出左鍵按下、還沒送出放開。
    private var pressed = false
    /// 捲動平均分到約 120 Hz 送出（`ScrollSmoother`），沒有要送的時候停掉。
    private var smoother = ScrollSmoother()
    private var scrollTimer: DispatchSourceTimer?
    private var lastScrollTick = 0.0

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

        // 優先最高幀率（延遲下限由幀間隔決定），其次畫面最高：鏡頭在螢幕上方，手放低時 16:9 會切掉手掌下半部。
        let formats = device.formats.compactMap { format -> (format: AVCaptureDevice.Format, range: AVFrameRateRange, size: CMVideoDimensions)? in
            guard let range = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return nil }
            return (format, range, CMVideoFormatDescriptionGetDimensions(format.formatDescription))
        }
        guard let best = HandTracker.preferred(formats, size: \.size).max(by: {
            ($0.range.maxFrameRate, $0.size.height, $0.size.width) < ($1.range.maxFrameRate, $1.size.height, $1.size.width)
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
        frameSize = (Int(best.size.width), Int(best.size.height))
    }

    /// 可選的格式：不是直式（直式左右太窄，手會碰到畫面邊緣），寬度在 1600 以內（手部模型不需要更高解析度）。
    /// 內建鏡頭上 1:1 的 1552×1552 比 16:9 多看到下方約一成五的畫面，推論時間不變；沒有合適的格式時全部都可選。
    static func preferred<T>(_ formats: [T], size: KeyPath<T, CMVideoDimensions>) -> [T] {
        let fitting = formats.filter { $0[keyPath: size].width >= $0[keyPath: size].height && $0[keyPath: size].width <= 1600 }
        return fitting.isEmpty ? formats : fitting
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
                scrollTimer?.cancel()
                scrollTimer = nil
                smoother = ScrollSmoother()
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
                if let button = output.button { Self.log.notice("button \(String(describing: button), privacy: .public)") }
                if output.rightClick {
                    Self.log.notice("right click")
                    rightClick(at: cursor)
                }
            }
            if output.escape {
                Self.log.notice("escape")
                pressEscape()
            }
            if let zoom = output.zoom {
                Self.log.notice("zoom \(zoom)")
                press(zoom: zoom)
            }
            if output.scrolling != nil, let rise = output.rise { Self.log.info("rise \(rise, format: .fixed(precision: 2))") }
            if let scroll = output.scroll {
                Self.log.notice("scroll \(scroll, format: .fixed(precision: 0))")
                smoother.add(scroll)
                startScrollTimer()
            }
            publish(output.state)
            publish(scrolling: output.scrolling)
            publish(mode: output.mode)
        }
    }

    private func controller(for calibration: Calibration) -> CursorController {
        CursorController(calibration: calibration, screenWidth: screen.width, screenHeight: screen.height)
    }

    /// 按著左鍵時移動要送拖曳事件。
    private func post(_ button: TapClicker.Button?, at cursor: Vec2) {
        let type: CGEventType = switch button {
        case .down: .leftMouseDown
        case .up: .leftMouseUp
        case nil: pressed ? .leftMouseDragged : .mouseMoved
        }
        send(type, at: point(cursor))
    }

    private func pressEscape() {
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    /// 放大送 ⌘=、縮小送 ⌘−，每格一次：瀏覽器、Finder、預覽程式等都用這組快捷鍵縮放。
    private func press(zoom: Int) {
        let key = CGKeyCode(zoom > 0 ? kVK_ANSI_Equal : kVK_ANSI_Minus)
        for _ in 0..<abs(zoom) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
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

    /// 在 `queue` 上約每 8 ms 送出一次捲動，送完就停。
    private func startScrollTimer() {
        guard scrollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        lastScrollTick = ProcessInfo.processInfo.systemUptime
        timer.setEventHandler { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            if let scroll = smoother.step(now - lastScrollTick) { send(scroll: scroll) }
            lastScrollTick = now
            if smoother.isIdle {
                scrollTimer?.cancel()
                scrollTimer = nil
            }
        }
        timer.resume()
        scrollTimer = timer
    }

    /// 像素單位的連續捲動，同觸控板。內容跟著指尖移動，不看系統的「自然捲動」設定：指尖往上時內容往上，等於滾輪
    /// 往下，所以正負相反。合成的捲動事件不會再套用這個設定（推論，待實機確認）。
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

    /// 狀態改變時通知主執行緒。光圈換狀態時會收起兩指提示。
    private func publish(_ state: ControlState) {
        guard state != self.state else { return }
        self.state = state
        scrolling = nil
        Self.log.notice("state \(String(describing: state), privacy: .public)")
        emit(.state(state))
        if state != .active { publish(mode: nil) }
    }

    private func publish(mode: ControlMode?) {
        guard mode != controlMode else { return }
        if mode == .zooming { Self.log.notice("zooming") }
        controlMode = mode
        emit(.mode(mode))
    }

    private func publish(scrolling: Scroller.Direction?) {
        guard scrolling != self.scrolling else { return }
        Self.log.notice("scrolling \(scrolling.map { String(describing: $0) } ?? "off", privacy: .public)")
        self.scrolling = scrolling
        emit(.scrolling(scrolling))
    }

    private func emit(_ event: Event) {
        let sink = self.sink
        DispatchQueue.main.async {
            MainActor.assumeIsolated { sink(event) }
        }
    }
}
