import Foundation
import IOKit.hid

/// MacBook 內建的加速度計：Apple Silicon 的 SPU 管理的 IMU（Bosch BMI286），M1 Pro 以後的 MacBook 才有。沒有公開 API：
/// 直接用 IOKit 開 vendor page 0xFF00、usage 3 的 `AppleSPUHIDDevice`，並在同 usage 的 `AppleSPUHIDDriver` 設電源與回報
/// 屬性，否則不會送資料。做法來自 olvvier/apple-silicon-accelerometer 與 AbdullahFID/MacSlapApp。
///
/// MirageCore 其他檔案都是純邏輯；這個讀取器放在這裡，是因為 App 與 mirage-spike 都要用。
/// 回呼與可變狀態都在 `queue` 上，因此標記為 @unchecked Sendable。
public final class Accelerometer: @unchecked Sendable {
    public struct Unavailable: Error, CustomStringConvertible {
        public let description: String
    }

    /// 一份報告 22 bytes：X、Y、Z 在 offset 6、10、14，int32 little-endian，Q16（除以 65536 是 g）。
    private static let reportSize = 22
    private static let bufferSize = 64
    private static let stallTimeout = 3.0

    private let interval: Int32
    private let onSample: @Sendable (_ t: Double, _ x: Double, _ y: Double, _ z: Double) -> Void
    private let queue = DispatchQueue(label: "mirage.accelerometer", qos: .userInteractive)
    /// mach 時間單位 → 秒。
    private let timebase: Double
    private var device: IOHIDDevice?
    private var watchdog: DispatchSourceTimer?
    /// 最後收到報告的時間（systemUptime）。
    private var lastReport = 0.0

    /// `interval`：回報間隔（µs），硬體最快約 800 Hz；設在 driver 上，全系統共用。`onSample` 在內部的序列 queue 上
    /// 呼叫，`t` 是報告的時間戳（秒，與 `ProcessInfo.systemUptime` 同一個時鐘），x、y、z 單位是 g。
    public init(interval: Int32, onSample: @escaping @Sendable (_ t: Double, _ x: Double, _ y: Double, _ z: Double) -> Void) {
        self.interval = interval
        self.onSample = onSample
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = Double(info.numer) / Double(info.denom) / 1e9
    }

    /// 開始讀取；找不到或打不開感測器時丟出 `Unavailable`。之後 3 秒沒有資料（例如睡眠喚醒後 SPU 停送）就重開。
    public func start() throws {
        try queue.sync {
            try open()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in
                self?.reopenIfStalled()
            }
            timer.resume()
            watchdog = timer
        }
    }

    public func stop() {
        queue.sync {
            watchdog?.cancel()
            watchdog = nil
            close()
        }
    }

    private func open() throws {
        guard let service = Self.service("AppleSPUHIDDevice") else {
            throw Unavailable(description: "找不到加速度計（需要 M1 Pro 以後的 Apple Silicon MacBook）")
        }
        defer { IOObjectRelease(service) }
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
            throw Unavailable(description: "IOHIDDeviceCreate 失敗")
        }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw Unavailable(description: "IOHIDDeviceOpen 失敗：\(Self.hex(result))")
        }
        // 電源與回報狀態在 driver 上；設在 device 上沒有作用（MacSlapApp 的經驗）。
        if let failure = wake() {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            throw Unavailable(description: failure)
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.bufferSize)
        // 取消後才釋放：取消前可能還有排隊中的回呼。
        let context = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(
            device, buffer, Self.bufferSize,
            { context, _, _, _, _, report, length, timestamp in
                guard let context else { return }
                Unmanaged<Accelerometer>.fromOpaque(context).takeUnretainedValue().handle(report, length, timestamp)
            },
            context
        )
        IOHIDDeviceSetDispatchQueue(device, queue)
        IOHIDDeviceSetCancelHandler(device) {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            buffer.deallocate()
            Unmanaged<Accelerometer>.fromOpaque(context).release()
        }
        IOHIDDeviceActivate(device)
        self.device = device
        lastReport = ProcessInfo.processInfo.systemUptime
    }

    private func close() {
        guard let device else { return }
        IOHIDDeviceCancel(device)
        self.device = nil
    }

    private func reopenIfStalled() {
        guard ProcessInfo.processInfo.systemUptime - lastReport > Self.stallTimeout else { return }
        close()
        // 失敗時下一秒再試。
        try? open()
    }

    /// 打開感測器的電源並設定回報間隔；失敗時回傳原因。
    private func wake() -> String? {
        guard let driver = Self.service("AppleSPUHIDDriver") else { return "找不到加速度計的 driver" }
        defer { IOObjectRelease(driver) }
        let properties: [(String, Int32)] = [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1), ("ReportInterval", interval)]
        for (key, value) in properties {
            // driver 只接受 SInt32 的 CFNumber。
            let result = IORegistryEntrySetCFProperty(driver, key as CFString, NSNumber(value: value))
            guard result == kIOReturnSuccess else { return "設定 \(key) 失敗：\(Self.hex(result))" }
        }
        return nil
    }

    private func handle(_ report: UnsafeMutablePointer<UInt8>, _ length: Int, _ timestamp: UInt64) {
        guard length >= Self.reportSize else { return }
        lastReport = ProcessInfo.processInfo.systemUptime
        func axis(_ offset: Int) -> Double {
            Double(Int32(littleEndian: UnsafeRawPointer(report + offset).loadUnaligned(as: Int32.self))) / 65536
        }
        onSample(Double(timestamp) * timebase, axis(6), axis(10), axis(14))
    }

    /// 加速度計（vendor page 0xFF00、usage 3）的 `className` 服務。
    private static func service(_ className: String) -> io_service_t? {
        let matching = IOServiceMatching(className) as NSMutableDictionary
        matching["IOPropertyMatch"] = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 3]
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        return service == 0 ? nil : service
    }

    private static func hex(_ result: IOReturn) -> String {
        String(format: "0x%08x", UInt32(bitPattern: result))
    }
}
