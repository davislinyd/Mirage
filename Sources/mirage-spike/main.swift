import AppKit
import MirageCore

// `mirage-spike [腳本] [--format 寬x高] [--frames] [--builtin]`：腳本預設 m0；格式預設同 App；`--frames` 只用於
// gaze，注視階段把影像存在本機 `recordings/`；`--builtin` 用內建螢幕，預設是目前的主要視窗所在的螢幕。
// `mirage-spike knock [--check]`：錄加速度計（敲掌托），見 `KnockRecorder`。
if CommandLine.arguments.dropFirst().first == "knock" {
    KnockRecorder.run(check: CommandLine.arguments.contains("--check"))
}
var arguments = Array(CommandLine.arguments.dropFirst())
let saveFrames = arguments.contains("--frames")
arguments.removeAll { $0 == "--frames" }
let builtinScreen = arguments.contains("--builtin")
arguments.removeAll { $0 == "--builtin" }
var size: (width: Int32, height: Int32)?
if let i = arguments.firstIndex(of: "--format") {
    let parts = arguments.dropFirst(i + 1).first?.split(separator: "x").compactMap { Int32($0) } ?? []
    guard parts.count == 2 else {
        print("--format 要寫成 寬x高，例如 1760x1328")
        exit(1)
    }
    size = (parts[0], parts[1])
    arguments.removeSubrange(i...i + 1)
}
let name = arguments.first ?? Script.m0.name
guard let script = Script.all.first(where: { $0.name == name }) else {
    print("沒有腳本 \(name)，可用：\(Script.all.map(\.name).joined(separator: "、"))")
    exit(1)
}
if saveFrames, !script.usesFace {
    print("--frames 只用於 gaze")
    exit(1)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = SpikeController(script: script, size: size, saveFrames: saveFrames, builtinScreen: builtinScreen)
    app.delegate = controller
    app.setActivationPolicy(.regular)
    app.run()
}
