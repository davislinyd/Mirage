// 依 OpenCV（AVFoundation 後端，devicesWithMediaType:）相同的順序列出鏡頭：編號、類型、名稱，以 tab 分隔。
import AVFoundation

for (index, device) in AVCaptureDevice.devices(for: .video).enumerated() {
    print("\(index)\t\(device.deviceType.rawValue)\t\(device.localizedName)")
}
