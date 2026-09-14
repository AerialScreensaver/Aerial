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

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Hand the scene-opening action to the AppKit side (Dock icon
        // click, Dock menu, launch presentation in the Dock presentation)
        // — the sanctioned way to open a SwiftUI `Window` scene from
        // outside a view. Idempotent; `body` may be re-evaluated.
        // swiftlint:disable:next redundant_discardable_let
        let _ = AppPresentationController.shared.register(openWindow: openWindow)

        // Video Library — declared as a SwiftUI Window scene so macOS
        // 26 (Tahoe) renders the modern chrome automatically: rounded
        // corners, traffic lights overlaid on the sidebar, no auto
        // sidebar-toggle item, collapsed search field. The previous
        // NSWindow + NSHostingController approach couldn't get there
        // because SwiftUI didn't fully own the window. Opened on
        // demand via `@Environment(\.openWindow)(id: "videoBrowser")`
        // — and, in the Dock presentation, by `AppPresentationController`
        // as the app's main window. Never presented at launch by SwiftUI
        // itself (`.suppressed`) and never restored (`.disabled`): the
        // controller decides, so a login-item launch stays windowless.
        // Size: `.defaultSize` only applies the very first time the window
        // is created; SwiftUI brings the user's last size back solely
        // through state restoration, which is disabled here — so
        // `AppPresentationController` persists and restores the frame
        // itself (see `registerLibraryWindow`).
        Window("Video Library", id: "videoBrowser") {
            WindowContentGate(onWindow: { AppPresentationController.shared.registerLibraryWindow($0) }) {
                VideoBrowserView()
            }
        }
        .defaultSize(width: 1320, height: 880)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            AerialCommands()
        }

        // Aerial Settings — same Tahoe-chrome reasoning as the Video
        // Library above. We do NOT use SwiftUI's `Settings` scene
        // because its window chrome is constrained and doesn't get
        // the full modern look. The Aerial-menu "Settings…" item (⌘,)
        // is wired by hand in `AerialCommands`.
        Window("Aerial Settings", id: "aerialSettings") {
            WindowContentGate {
                SettingsView()
            }
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

/// Dismounts a window scene's content while its NSWindow is closed.
///
/// SwiftUI `Window` scenes keep their NSWindow alive after the user
/// closes it, and a closed window's still-mounted tree keeps its
/// WindowServer notification handlers registered. With the wallpaper
/// animating, those handlers fired 10-15×/s into tracking-area /
/// structural-region / drag-type re-registration churn — ~4.5% CPU
/// with every window closed (2026-07-25 sample; same disease as the
/// popover's `PopoverVisibility` fix, window-scene edition).
///
/// Wrap the scene root: content dismounts on the window's
/// `willCloseNotification` and remounts when the window becomes key
/// again. Trade-off: root `@State`/`@StateObject` (panel selection,
/// browser navigation) reset on each reopen.
struct WindowContentGate<Content: View>: View {
    /// Called synchronously as soon as the hosting NSWindow exists (from
    /// the grabber view's `viewDidMoveToWindow`, i.e. during window
    /// construction, before it is on screen) — lets the scene hand its
    /// window to AppKit-side code (`AppPresentationController`) early
    /// enough to restore a saved frame without a visible jump.
    var onWindow: ((NSWindow) -> Void)? = nil
    @ViewBuilder let content: () -> Content

    @State private var isOpen = true
    @State private var window: NSWindow?

    var body: some View {
        Group {
            if isOpen {
                content()
            } else {
                Color.clear
            }
        }
        .background(WindowGrabber(window: $window, onWindow: onWindow))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let window, (note.object as? NSWindow) === window {
                isOpen = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let window, (note.object as? NSWindow) === window {
                isOpen = true
            }
        }
    }
}

/// Reports the hosting NSWindow of the view it backgrounds. Stays
/// mounted across the gate's open/closed branches so the window
/// reference survives dismounts.
private struct WindowGrabber: NSViewRepresentable {
    @Binding var window: NSWindow?
    var onWindow: ((NSWindow) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = GrabberView()
        view.onWindow = onWindow
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if window == nil { window = view.window } }
    }

    /// Reports its window the moment it gets one — synchronously, during
    /// the window's construction — for callers that must act before the
    /// window is shown.
    private final class GrabberView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
