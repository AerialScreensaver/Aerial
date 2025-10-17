//
//  PathMigrationWindowController.swift
//  Aerial Companion
//
//  Window controller for container data migration UI
//

import Cocoa
import SwiftUI

@available(macOS 11.0, *)
class PathMigrationWindowController: NSWindowController {

    private var onComplete: (() -> Void)?

    convenience init() {
        // Create window with hosting controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Aerial Data Migration"
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
    }

    override func windowDidLoad() {
        super.windowDidLoad()

        // Create SwiftUI view
        let migrationView = PathMigrationView(
            isCustomCacheUser: PathMigration.isCustomCacheUser(),
            description: PathMigration.getMigrationDescription(),
            onMigrate: { [weak self] type, progressCallback, completion in
                self?.performMigration(type: type, progressCallback: progressCallback, completion: completion)
            },
            onShowOldLocation: {
                PathMigration.showOldContainerInFinder()
            },
            onShowNewLocation: {
                PathMigration.showNewLocationInFinder()
            },
            onDismiss: { [weak self] in
                self?.close()
                self?.onComplete?()
            }
        )

        // Wrap in hosting controller
        let hostingController = NSHostingController(rootView: migrationView)
        window?.contentViewController = hostingController
    }

    // MARK: - Migration

    private func performMigration(
        type: MigrationType,
        progressCallback: @escaping (String) -> Void,
        completion: @escaping (MigrationResult) -> Void
    ) {
        PathMigration.performMigration(
            type: type,
            progressCallback: progressCallback,
            completion: completion
        )
    }

    // MARK: - Public Interface

    /// Show the migration window modally
    /// - Parameter onComplete: Called when user dismisses the window
    func showModal(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: window!)
    }

    /// Close the modal window
    override func close() {
        NSApp.stopModal()
        super.close()
    }
}
