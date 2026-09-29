import AppKit
import VigilCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var statusController: StatusItemController!
    private var windows: AuxWindowManager!
    private var notch: EdgeNotchController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.run(into: CommandLine.arguments[i + 1]) { NSApp.terminate(nil) }
            return
        }
        model = AppModel()
        statusController = StatusItemController(model: model)
        windows = AuxWindowManager(model: model)
        notch = EdgeNotchController(model: model)
        model.onChange = { [weak self] in
            self?.statusController.refresh()
            self?.notch.refresh()
        }
        model.onOpenWindow = { [weak self] kind in
            self?.statusController.closePopover()
            self?.windows.show(kind)
        }
        model.onUISettingsChange = { [weak self] in self?.notch.apply() }
        notch.apply()
        model.start()
        statusController.refresh()

        if !model.settings.hasSeenOnboarding {
            // First launch: open the popover with the setup checklist.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                statusController.showPopover()
                model.markOnboardingSeen()
            }
        }
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the popover: a menu bar app has no window to raise.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusController?.showPopover()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }
}
