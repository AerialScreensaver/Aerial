//
//  DashboardOverlayStatusRow.swift
//  Aerial Companion
//
//  Conveys whether overlays are common to all displays (default) or
//  per-screen, and opens the overlay editor — scoped to the given screen
//  when overlays are per-screen.
//

import SwiftUI

struct DashboardOverlayStatusRow: View {
    /// nil = shared/global context; non-nil = a specific display's card.
    let screenUUID: String?
    /// Whether overlays are configured per-screen.
    let perScreen: Bool

    /// Retains the editor window so it isn't deallocated immediately.
    static var editorController: OverlayEditorWindowController?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "textformat")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            Spacer(minLength: 0)

            Button(action: openEditor) {
                Label("Edit Overlays", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .help("Open the overlay editor")
        }
    }

    private var label: String {
        if perScreen {
            return screenUUID == nil ? "Overlays: per-screen" : "Overlays for this display"
        }
        return "Overlays shared across all displays"
    }

    private func openEditor() {
        // Only scope to a specific screen when overlays are actually per-screen.
        let scoped: String? = perScreen ? screenUUID : nil

        // Reuse an already-open editor, but retarget it to the requested
        // scope so opening it for a different display updates the picker and
        // preview rather than showing the stale one.
        if let existing = Self.editorController, existing.window?.isVisible == true {
            existing.retarget(screenUUID: scoped)
            existing.showEditorWindow()
            return
        }
        let onScreen = screenUUID.flatMap { NSScreen.getScreenByUuid($0) }
            ?? NSApp.keyWindow?.screen ?? NSScreen.main
        let controller = OverlayEditorWindowController(screenUUID: scoped, onScreen: onScreen)
        Self.editorController = controller
        controller.showEditorWindow()
    }
}
