import CueCore
import AppKit
import Carbon.HIToolbox
import SwiftUI

struct CueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // The menubar item lives in AppDelegate. The empty Settings scene drops its ⌘, command too.
    var body: some Scene { Settings { EmptyView() }.commands { CommandGroup(replacing: .appSettings) {} } }
}

/// Owns the menubar item and its popover. SwiftUI's MenuBarExtra can't open from code, which the
/// global hotkey needs; an NSStatusItem with an NSPopover can.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = AppModel()
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var hotKey: HotKey?
    private var closedAt = Date.distantPast
    /// A 1-point stand-in for the icon while the menubar is hidden.
    private let anchor: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: true)
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return w
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Cue's mark from the bundle, drawn as a template so it follows the menubar's light or dark look.
        // A build run from .build/ has no bundle resources and shows the SF Symbol instead.
        let mark = Bundle.main.url(forResource: "menubar", withExtension: "tiff").flatMap(NSImage.init(contentsOf:))
        mark?.isTemplate = true
        mark?.size = NSSize(width: 18, height: 18)
        mark?.accessibilityDescription = "Cue"
        item.button?.image = mark ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "Cue")
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(clicked)
        self.item = item

        let host = NSHostingController(rootView: PopoverView().environment(model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        showCount()
        model.notifier.onOpen = { [weak self] id in self?.show(focusing: id) }
        model.notifier.popoverShown = { [weak self] in self?.popover.isShown ?? false }
        model.notifier.start()
        LoginItem.apply()
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)) { [weak self] in self?.toggle() }
    }

    /// Keeps the menubar count current: Observation calls back once per change, so each call re-arms it.
    private func showCount() {
        withObservationTracking {
            let n = model.waiting
            item?.button?.title = n > 0 ? " \(n)" : ""
        } onChange: { [weak self] in
            Task { @MainActor in self?.showCount() }
        }
    }

    @objc private func clicked() {
        // A click on the icon closes the transient popover first, then lands here: don't reopen it.
        if Date().timeIntervalSince(closedAt) > 0.3 { toggle() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.notifier.stop()  // the hooks' terminal banners take over again
    }

    /// Opens the popover on one session, for a notification you clicked.
    func show(focusing id: String) {
        model.focusRequest = id
        if !popover.isShown { toggle() }
    }

    func popoverDidClose(_ notification: Notification) {
        closedAt = Date()
        anchor.orderOut(nil)
    }

    func toggle() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item?.button, let bar = button.window else { return }
        model.resort()
        // An app without a Dock icon has to activate itself, or the text areas won't take keys.
        NSApp.activate(ignoringOtherApps: true)
        // A hidden menubar (a full-screen app, or auto-hide) leaves the icon above the screen, and NSPopover
        // closes the moment it resizes against an offscreen anchor. Point at the screen's top edge instead.
        let screen = NSScreen.screens.first { $0.frame.minX <= bar.frame.midX && bar.frame.midX < $0.frame.maxX } ?? NSScreen.main
        if let screen, bar.frame.minY >= screen.frame.maxY - 1, let view = anchor.contentView {
            anchor.setFrame(NSRect(x: bar.frame.midX, y: screen.frame.maxY - 1, width: 1, height: 1), display: false)
            anchor.orderFrontRegardless()
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }
}
