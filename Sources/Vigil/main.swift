import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // no Dock icon, no Cmd+Tab entry (also set via LSUIElement)
    app.run()
}
