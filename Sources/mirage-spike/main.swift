import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = SpikeController()
    app.delegate = controller
    app.setActivationPolicy(.regular)
    app.run()
}
