import Cocoa
import SwiftUI

/// Restore an autosaved AppKit window frame, or center the window the first time
/// it is shown. Checking `frameAutosaveName` after assigning it never detects a
/// missing saved frame because the property is non-empty by construction.
func restoreFrameOrCenter(_ window: NSWindow, name: NSWindow.FrameAutosaveName) {
    let restored = window.setFrameUsingName(name)
    window.setFrameAutosaveName(name)
    if !restored { window.center() }
}

/// Hosts the library UI in a real, dockable window with proper macOS chrome.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let controller: MenuBarController

    init(controller: MenuBarController) {
        self.controller = controller

        let host = NSHostingController(
            rootView: PopoverContentView(controller: controller, isWindow: true)
                .environmentObject(controller.recorder)
                .environmentObject(controller.player)
                .environmentObject(controller.state)
                .environmentObject(controller.library)
        )

        let win = NSWindow(contentViewController: host)
        win.title = "TinyRecorder"
        win.setContentSize(NSSize(width: 720, height: 460))
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        win.minSize = NSSize(width: 620, height: 390)
        win.isReleasedWhenClosed = false
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.toolbarStyle = .unified
        win.backgroundColor = .clear
        win.isMovableByWindowBackground = true
        // New autosave key intentionally resets the former dashboard-sized frame
        // to this compact utility footprint on first launch of the redesign.
        restoreFrameOrCenter(win, name: "TinyRecorder.MainWindow.CompactV2")
        super.init(window: win)
        win.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Dedicated Settings window (HIG: Settings belongs in its own window,
/// not a popover spawned inside the menu-bar popover).
final class SettingsWindowController: NSWindowController {
    init(controller: MenuBarController) {
        let host = NSHostingController(
            rootView: SettingsPanel(controller: controller, inWindow: true)
                .environmentObject(controller.state)
                .environmentObject(controller.library)
        )
        let win = NSWindow(contentViewController: host)
        win.title = "Settings"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        let settingsSize = NSSize(width: 580, height: 430)
        win.setContentSize(settingsSize)
        win.contentMinSize = settingsSize
        win.contentMaxSize = settingsSize
        restoreFrameOrCenter(win, name: "TinyRecorder.Settings")
        super.init(window: win)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
