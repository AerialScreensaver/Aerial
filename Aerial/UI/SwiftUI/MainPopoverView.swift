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
    var onSetAsDefault: () async -> Void

    // State for conditional displays
    @State private var isAerialDefault: Bool = true
    @State private var isCheckingDefault: Bool = true
    @State private var solidBackground: Bool = Preferences.popoverSolidBackground

    @State private var updateAvailable: Bool = false
    @State private var hasImmediateInstall: Bool = false

    var body: some View {
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
            
            // Conditional alert bars
            if !isCheckingDefault && !isAerialDefault {
                Divider()
                    .padding(.vertical, 8)

                NotDefaultBarView(onSetAsDefault: {
                    await onSetAsDefault()
                    // Refresh the check after setting
                    await checkIfAerialIsDefault()
                })
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
                version: "Aerial \(Helpers.version)",
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
        .task {
            await checkIfAerialIsDefault()
        }
        // The popover's NSHostingController is persistent — SwiftUI's
        // `.task` only fires once for the lifetime of the host, so it
        // never re-runs on later popover opens. Subscribe to AppKit's
        // pre-show signal so we re-check the active-Space screensaver
        // every time the popover is about to become visible (catches
        // users changing the screensaver in System Settings while
        // Aerial is running).
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in
            Task { await checkIfAerialIsDefault() }
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

    private func checkIfAerialIsDefault() async {
        isCheckingDefault = true
        AerialPluginManager.shared.checkScreensaverEnabled()
        isAerialDefault = AerialPluginManager.shared.isScreensaverEnabled
        isCheckingDefault = false
    }
}

struct MainPopoverView_Previews: PreviewProvider {
    static var previews: some View {
        MainPopoverView(
            playbackManager: PlaybackManager.shared,
            onOpenVideoBrowser: {},
            onOpenCompanionSettings: {},
            onOpenInfo: {},
            onExit: {},
            onDismiss: {},
            onSetAsDefault: {}
        )
    }
}
