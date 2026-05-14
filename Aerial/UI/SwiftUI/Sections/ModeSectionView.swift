//
//  ModeSectionView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

/// Top row with three equal mode buttons: Lock Screen, Desktop, Fullscreen
struct ModeSectionView: View {
    @ObservedObject var playbackManager: PlaybackManager
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Lock Screen button
            Button(action: {
                playbackManager.startScreensaver()
                onDismiss()
            }) {
                modeLabel(icon: "lock.display", title: "Lock Screen")
            }
            .buttonStyle(.plain)
            .help("Start the screensaver now")

            // Desktop button — Menu on multi-monitor, plain toggle on single-monitor
            if playbackManager.availableScreens.count > 1 {
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

                    Divider()

                    let allActive = playbackManager.availableScreens.allSatisfy {
                        playbackManager.isScreenActive($0.uuid)
                    }

                    Button(action: {
                        if allActive {
                            playbackManager.stop()
                        } else {
                            playbackManager.startDesktopOnAllScreens()
                        }
                        onDismiss()
                    }) {
                        HStack {
                            Text("All Screens")
                            Spacer()
                            if allActive {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } label: {
                    modeLabel(
                        icon: "menubar.dock.rectangle",
                        title: "Wallpaper",
                        showChevron: true,
                        isActive: playbackManager.playbackMode == .desktop
                    )
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("Play Aerial as your wallpaper")
            } else {
                Button(action: {
                    if let uuid = playbackManager.availableScreens.first?.uuid {
                        playbackManager.toggleDesktopLauncher(for: uuid)
                    }
                    onDismiss()
                }) {
                    modeLabel(
                        icon: "menubar.dock.rectangle",
                        title: "Wallpaper",
                        showChevron: false,
                        isActive: playbackManager.playbackMode == .desktop
                    )
                }
                .buttonStyle(.plain)
                .help("Play Aerial as your wallpaper")
            }

            // Fullscreen button
            Button(action: {
                if playbackManager.playbackMode == .monitor {
                    playbackManager.stop()
                } else {
                    playbackManager.startWindowMode()
                }
                onDismiss()
            }) {
                modeLabel(
                    icon: "arrow.up.backward.and.arrow.down.forward",
                    title: "Fullscreen",
                    isActive: playbackManager.playbackMode == .monitor
                )
            }
            .buttonStyle(.plain)
            .help("Play Aerial fullscreen on the active screen")
        }
    }

    private func modeLabel(
        icon: String,
        title: String,
        showChevron: Bool = false,
        isActive: Bool = false
    ) -> some View {
        VStack(spacing: 4) {
            Image(systemName: isActive ? "stop.fill" : icon)
                .font(.system(size: 20, weight: .semibold))
            if showChevron {
                HStack(spacing: 2) {
                    Text(title)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                }
                .font(.body)
            } else {
                Text(title)
                    .font(.body)
            }
        }
        .foregroundColor(.aerial)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.aerial.opacity(isActive ? 0.25 : 0.1))
        .cornerRadius(8)
        .contentShape(Rectangle())
    }
}

struct ModeSectionView_Previews: PreviewProvider {
    static var previews: some View {
        ModeSectionView(
            playbackManager: PlaybackManager.shared,
            onDismiss: {}
        )
        .padding()
        .frame(width: 380)
    }
}
