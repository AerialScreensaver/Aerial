//
//  DesktopModeSectionView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

/// Desktop mode controls: Desktop wallpaper picker and Fullscreen button
@available(macOS 11.0, *)
struct DesktopModeSectionView: View {
    @ObservedObject var playbackManager: PlaybackManager
    var onOpenSettings: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Desktop wallpaper picker menu
            Menu {
                ForEach(playbackManager.availableScreens) { screen in
                    Button(action: {
                        playbackManager.toggleDesktopLauncher(for: screen.uuid)
                        onDismiss()
                    }) {
                        HStack {
                            Text(screen.name)
                            Spacer()
                            if playbackManager.isScreenActive(screen.uuid) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                if playbackManager.availableScreens.count > 1 {
                    Divider()

                    Button("All Screens") {
                        playbackManager.startDesktopOnAllScreens()
                        onDismiss()
                    }
                }
            } label: {
                Label("Desktop", systemImage: "menubar.dock.rectangle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Fullscreen/window mode button
            Button(action: {
                playbackManager.startWindowMode()
                onDismiss()
            }) {
                Label("Fullscreen", systemImage: "arrow.up.backward.and.arrow.down.forward")
            }
            .buttonStyle(.bordered)

            Spacer()

            // Settings button
            Button(action: onOpenSettings) {
                Image(systemName: "gear")
                    .font(.system(size: 25))
            }
            .buttonStyle(.borderless)
            .help("Open Aerial Settings")
        }
    }
}

@available(macOS 11.0, *)
struct DesktopModeSectionView_Previews: PreviewProvider {
    static var previews: some View {
        DesktopModeSectionView(
            playbackManager: PlaybackManager.shared,
            onOpenSettings: {},
            onDismiss: {}
        )
        .padding()
        .frame(width: 280)
    }
}
