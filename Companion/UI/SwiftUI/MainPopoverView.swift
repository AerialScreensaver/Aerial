//
//  MainPopoverView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

/// Main popover view containing all UI sections
@available(macOS 11.0, *)
struct MainPopoverView: View {
    @ObservedObject var playbackManager: PlaybackManager

    // Callbacks for window operations (handled by AppDelegate)
    var onOpenSettings: () -> Void           // Opens Aerial screensaver settings
    var onOpenCompanionSettings: () -> Void  // Opens Companion app settings (SettingsView)
    var onOpenInfo: () -> Void
    var onOpenHelp: () -> Void
    var onExit: () -> Void
    var onDismiss: () -> Void
    var onSetAsDefault: () async -> Void
    var onUpdateNow: () -> Void

    // State for conditional displays
    @State private var isAerialDefault: Bool = true
    @State private var isCheckingDefault: Bool = true
    @State private var updateMessage: String = "A new version is available!"

    var body: some View {
        VStack(spacing: 0) {
            // Section 1: Lock Screen (prominent, at top)
            LockSectionView(
                playbackManager: playbackManager,
                onDismiss: onDismiss
            )
            .padding(.bottom, 12)

            Divider()
                .padding(.vertical, 8)

            // Section 2: Desktop Mode Controls
            DesktopModeSectionView(
                playbackManager: playbackManager,
                onOpenSettings: onOpenSettings,
                onDismiss: onDismiss
            )
            .padding(.bottom, 12)

            Divider()
                .padding(.vertical, 8)

            // Section 3: Playback Controls (always visible)
            PlaybackSectionView(playbackManager: playbackManager)

            // Conditional alert bars
            if playbackManager.hasUpdate {
                Divider()
                    .padding(.vertical, 8)

                UpdateBarView(
                    message: updateMessage,
                    onUpdateNow: onUpdateNow
                )
            }

            if !isCheckingDefault && !isAerialDefault {
                Divider()
                    .padding(.vertical, 8)

                NotDefaultBarView(onSetAsDefault: {
                    await onSetAsDefault()
                    // Refresh the check after setting
                    await checkIfAerialIsDefault()
                })
            }

            Divider()
                .padding(.vertical, 8)

            // Section 4: Bottom Bar
            BottomBarView(
                version: "Aerial \(Helpers.version)",
                onOpenInfo: onOpenInfo,
                onOpenSettings: onOpenCompanionSettings,  // Opens Companion settings, not Aerial settings
                onOpenHelp: onOpenHelp,
                onExit: onExit
            )
        }
        .padding(12)
        .frame(width: 380)
        .task {
            await checkIfAerialIsDefault()
        }
    }

    // MARK: - Private Methods

    private func checkIfAerialIsDefault() async {
        isCheckingDefault = true
        let isActive = await Task.detached {
            ScreensaverManager.shared.isAerialActive()
        }.value
        isAerialDefault = isActive
        isCheckingDefault = false
    }

    /// Update the message shown in the update bar
    func updateProgress(message: String) {
        updateMessage = message
    }
}

@available(macOS 11.0, *)
struct MainPopoverView_Previews: PreviewProvider {
    static var previews: some View {
        MainPopoverView(
            playbackManager: PlaybackManager.shared,
            onOpenSettings: {},
            onOpenCompanionSettings: {},
            onOpenInfo: {},
            onOpenHelp: {},
            onExit: {},
            onDismiss: {},
            onSetAsDefault: {},
            onUpdateNow: {}
        )
    }
}
