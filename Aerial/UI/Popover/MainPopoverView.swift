//
//  MainPopoverView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import Combine
import SwiftUI

/// Main popover view containing all UI sections
struct MainPopoverView: View {
    @ObservedObject var playbackManager: PlaybackManager

    // Callbacks for window operations (handled by AppDelegate)
    var onOpenVideoBrowser: () -> Void       // Opens Video Library browser
    var onOpenCompanionSettings: () -> Void  // Opens Companion app settings (SettingsView)
    var onOpenInfo: () -> Void
    var onExit: () -> Void
    var onDismiss: () -> Void

    // State for conditional displays
    @State private var wallpaperNeedsSetup: Bool = false
    @State private var screensaverNeedsSetup: Bool = false
    @State private var solidBackground: Bool = Preferences.popoverSolidBackground

    @State private var updateAvailable: Bool = false
    @State private var hasImmediateInstall: Bool = false

    @ObservedObject private var visibility = PopoverVisibility.shared

    var body: some View {
        // Dismount EVERYTHING while the popover is closed: the hosting
        // controller is persistent, so a closed popover's tree stays
        // alive — an indeterminate spinner left mounted (playlist
        // "Building…" state, nag bars) kept SwiftUI's display link
        // committing to WindowServer every frame, ~10% CPU invisible
        // (2026-07-25 sample). Unmounted views can't animate, tick, or
        // subscribe; section `.onAppear`s re-run on every open, which
        // is exactly the refresh the old willShow observers provided.
        if visibility.isShown {
            popoverContent
        } else {
            Color.clear.frame(width: 380, height: 1)
        }
    }

    private var popoverContent: some View {
        VStack(spacing: 0) {
            // Section 1: Mode buttons (Lock Screen, Desktop, Fullscreen)
            ModeSectionView(
                playbackManager: playbackManager,
                onDismiss: onDismiss
            )
            .padding(.bottom, 4)

            Divider()
                .padding(.vertical, 8)

            // Section 3: Now Playing source picker
            NowPlayingSectionView(playbackManager: playbackManager)

            Divider()
                .padding(.vertical, 8)

            // Playlist strip (horizontal scrolling thumbnails)
            PlaylistSectionView(playbackManager: playbackManager)

            // System pause reason (coverage/battery/thermal/camera) —
            // same text as the Dashboard cards, scoped to the display
            // the popover opened on.
            if let mention = playbackManager.pauseMention(for: playbackManager.popoverScreenUUID) {
                Label(mention.text, systemImage: mention.icon)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
            }

            // Conditional alert bars — nag when a role the user chose at first
            // launch isn't actually set (e.g. they removed it in System Settings).
            if wallpaperNeedsSetup {
                Divider()
                    .padding(.vertical, 8)

                NotDefaultBarView(message: "Aerial 4 isn't your wallpaper yet") {
                    _ = await WallpaperControl.setAerialAsWallpaper()
                    refreshSetupChecks()
                }
            }

            if screensaverNeedsSetup {
                Divider()
                    .padding(.vertical, 8)

                NotDefaultBarView(message: "Aerial 4 isn't your screensaver yet") {
                    _ = await WallpaperControl.setAerialAsScreensaver()
                    refreshSetupChecks()
                }
            }

            if updateAvailable {
                Divider()
                    .padding(.vertical, 8)

                UpdateAvailableBarView(isReadyToInstall: hasImmediateInstall, onInstall: {
                    if let handler = AppDelegate.shared?.sparkleGentleDelegate.immediateInstallHandler {
                        handler()
                    } else {
                        AppDelegate.shared?.sparkleController.updater.checkForUpdates()
                    }
                })
            }

            Divider()
                .padding(.top, 14)
                .padding(.bottom, 2)

            // Section 4: Bottom Bar
            BottomBarView(
                version: Helpers.version,
                onOpenInfo: onOpenInfo,
                onOpenVideoBrowser: onOpenVideoBrowser,
                onOpenSettings: onOpenCompanionSettings,
                onExit: onExit
            )
        }
        .padding(12)
        .frame(width: 380)
        .background(solidBackground ? Color(NSColor.windowBackgroundColor) : Color.clear)
        .tint(.aerial)
        .onReceive(NotificationCenter.default.publisher(for: .popoverSolidBackgroundDidChange)) { notification in
            solidBackground = (notification.object as? Bool) ?? Preferences.popoverSolidBackground
        }
        .onReceive(updateAvailablePublisher) { newValue in
            updateAvailable = newValue
        }
        .onReceive(immediateInstallPublisher) { newValue in
            hasImmediateInstall = newValue
        }
        .onAppear {
            refreshSetupChecks()
        }
        // The popover's NSHostingController is persistent, so `.onAppear`
        // only fires once for the lifetime of the host. Subscribe to AppKit's
        // pre-show signal so we re-check the active wallpaper/screensaver
        // every time the popover is about to become visible (catches users
        // changing them in System Settings while Aerial is running).
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in
            refreshSetupChecks()
        }
    }

    // MARK: - Private Methods

    private var updateAvailablePublisher: AnyPublisher<Bool, Never> {
        guard let delegate = AppDelegate.shared?.sparkleGentleDelegate else {
            return Just(false).eraseToAnyPublisher()
        }
        return delegate.$updateAvailable.eraseToAnyPublisher()
    }

    private var immediateInstallPublisher: AnyPublisher<Bool, Never> {
        guard let delegate = AppDelegate.shared?.sparkleGentleDelegate else {
            return Just(false).eraseToAnyPublisher()
        }
        return delegate.$immediateInstallHandler
            .map { $0 != nil }
            .eraseToAnyPublisher()
    }

    /// Recompute the nag bars: nag for a role only if the user chose it at first
    /// launch and it isn't currently the active wallpaper/screensaver. All three
    /// modes set the screensaver; only paused/animated set the wallpaper.
    private func refreshSetupChecks() {
        let chosen = Preferences.wallpaperModeChosen
        let wantsWallpaper = Preferences.wallpaperMode == .paused || Preferences.wallpaperMode == .animated
        wallpaperNeedsSetup = chosen && wantsWallpaper && (WallpaperControl.isAerialSystemWallpaper() != true)
        screensaverNeedsSetup = chosen && (WallpaperControl.isAerialSystemScreensaver() != true)
    }
}

/// Whether the menubar popover is currently on screen. AppDelegate
/// flips it (true in `showPopover` before `popover.show`, false on
/// `NSPopover.didCloseNotification` — which also covers transient
/// outside-click closes). `MainPopoverView.body` gates its whole
/// content on this so nothing stays mounted — and nothing can burn
/// CPU — while the popover is closed.
@MainActor
final class PopoverVisibility: ObservableObject {
    static let shared = PopoverVisibility()

    @Published var isShown = false

    private init() {}
}

struct MainPopoverView_Previews: PreviewProvider {
    static var previews: some View {
        MainPopoverView(
            playbackManager: PlaybackManager.shared,
            onOpenVideoBrowser: {},
            onOpenCompanionSettings: {},
            onOpenInfo: {},
            onExit: {},
            onDismiss: {}
        )
    }
}
