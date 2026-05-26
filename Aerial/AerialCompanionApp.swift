//
//  AerialCompanionApp.swift
//  Aerial Companion
//
//  Created by SwiftUI Migration on 18/08/2024.
//

import SwiftUI

@main
struct AerialCompanionApp: App {
    // Preserve all existing AppDelegate functionality
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Video Library — declared as a SwiftUI Window scene so macOS
        // 26 (Tahoe) renders the modern chrome automatically: rounded
        // corners, traffic lights overlaid on the sidebar, no auto
        // sidebar-toggle item, collapsed search field. The previous
        // NSWindow + NSHostingController approach couldn't get there
        // because SwiftUI didn't fully own the window. Opened on
        // demand via `@Environment(\.openWindow)(id: "videoBrowser")`.
        Window("Video Library", id: "videoBrowser") {
            VideoBrowserView()
        }
        .defaultLaunchBehavior(.suppressed)

        // Aerial Settings — same Tahoe-chrome reasoning as the Video
        // Library above. We do NOT use SwiftUI's `Settings` scene
        // because its window chrome is constrained and doesn't get
        // the full modern look. The trade-off is that the Apple-menu
        // "Settings…" item is no longer auto-wired, but Aerial is a
        // menubar utility — the popover gear button (with the ⌘,
        // shortcut) is the actual entry point users hit.
        Window("Aerial Settings", id: "aerialSettings") {
            SettingsView()
        }
        .defaultLaunchBehavior(.suppressed)
    }
}
