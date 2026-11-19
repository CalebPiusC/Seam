import AppKit
import SwiftUI

/// Menu-bar-only app: an SF Symbol status item that opens the SEAM popover. No Dock icon, no windows.
@MainActor
public final class SeamMenuBarController: NSObject, NSApplicationDelegate {
    private let model: SeamAppViewModel
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    public init(bootstrapper: UsbBootstrapper) {
        self.model = SeamAppViewModel(bootstrapper: bootstrapper)
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        let hosting = NSHostingController(
            rootView: SeamPopoverView(model: model, onQuit: { NSApp.terminate(nil) })
        )
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        model.onStatusChange = { [weak self] in self?.refreshStatusIcon() }
        refreshStatusIcon()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        let symbolName = model.routingTarget == .android ? "smartphone" : "laptopcomputer.and.iphone"
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = (NSImage(systemSymbolName: symbolName, accessibilityDescription: "SEAM")
            ?? NSImage(systemSymbolName: "display", accessibilityDescription: "SEAM"))?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !model.isConnected
        button.toolTip = model.isConnected ? "SEAM — \(model.deviceName)" : "SEAM — Looking for your phone"
    }
}
