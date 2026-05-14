//
//  FirstLaunchWizardWindowController.swift
//  Aerial Companion
//
//  Window controller for the first-launch setup wizard. Shape mirrors
//  PathMigrationWindowController — modal, centered, hosts the SwiftUI
//  wizard view. The wizard owns its own step progression including the
//  conditional migration step.
//

import Cocoa
import SwiftUI

class FirstLaunchWizardWindowController: NSWindowController {

    private var onComplete: (() -> Void)?

    convenience init() {
        // No `.closable` — the user is forced through Back / Next so we
        // know the prefs we wrote (and the completion sentinel) are in
        // a consistent state when the window goes away.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Aerial 4 !"
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
    }

    override func windowDidLoad() {
        super.windowDidLoad()

        let view = FirstLaunchWizardView { [weak self] in
            self?.close()
            self?.onComplete?()
        }

        let hosting = NSHostingController(rootView: view)
        window?.contentViewController = hosting
    }

    /// Show the wizard modally and call `onComplete` when the user
    /// finishes step 3. Mirrors `PathMigrationWindowController.showModal`.
    func showModal(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: window!)
    }

    override func close() {
        NSApp.stopModal()
        super.close()
    }
}
