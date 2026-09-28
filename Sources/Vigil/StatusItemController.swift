import AppKit
import SwiftUI
import VigilCore

/// NSStatusItem + NSPopover: gives us right-click, template icons that follow state, and click-outside-to-close.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var lastIcon = ""
    private var lastTitle: String?

    init(model: AppModel) {
        self.model = model
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 600)
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("Vigil")
        }
        model.onChange = { [weak self] in self?.refresh() }
    }

    func refresh() {
        guard let button = statusItem.button else { return }
        let icon = model.iconName
        if icon != lastIcon {
            lastIcon = icon
            let image = NSImage(systemSymbolName: icon, accessibilityDescription: "Vigil")?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            image?.isTemplate = true
            button.image = image
        }
        let title = model.statusItemTitle
        if title != lastTitle {
            lastTitle = title
            if let title {
                button.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
            } else {
                button.title = ""
            }
        }
        button.toolTip = tooltip()
    }

    private func tooltip() -> String {
        switch model.phase {
        case .off: return L("Vigil is off")
        case .armed: return L("Armed · waiting for Claude")
        case .working: return L("Claude is working · %@", Format.clock(model.workingElapsed))
        case .countdown: return L("Sleeping in %@", Format.clock(model.countdownRemaining ?? 0))
        }
    }

    // MARK: click handling

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover(tab: Tab? = nil) {
        guard let button = statusItem.button else { return }
        if let tab { model.tab = tab }
        model.refreshSetup()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        if popover.isShown { popover.performClose(nil) }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: model.enabled ? L("Turn off") : L("Turn on"), action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        let sleep = NSMenuItem(title: L("Sleep now"), action: #selector(sleepNow), keyEquivalent: "")
        sleep.target = self
        let settings = NSMenuItem(title: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let quit = NSMenuItem(title: L("Quit Vigil"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        for item in [toggle, sleep, .separator(), settings, .separator(), quit] { menu.addItem(item) }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // restore left-click = popover
    }

    @objc private func toggleEnabled() { model.toggle() }
    @objc private func sleepNow() { model.sleepNow() }
    @objc private func openSettings() { showPopover(tab: .settings) }
    @objc private func quit() { model.quit() }
}
