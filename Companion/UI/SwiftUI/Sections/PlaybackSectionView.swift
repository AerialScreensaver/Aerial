//
//  PlaybackSectionView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

/// Playback controls section - always visible, disabled when nothing is playing
@available(macOS 11.0, *)
struct PlaybackSectionView: View {
    @ObservedObject var playbackManager: PlaybackManager

    private var isDisabled: Bool {
        playbackManager.playbackMode == .none
    }

    var body: some View {
        VStack(spacing: 12) {
            // Control buttons row
            HStack(spacing: 16) {
                // Stop
                IconButton(
                    systemImage: "stop.fill",
                    label: "Stop",
                    action: { playbackManager.stop() }
                )
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.4 : 1.0)

                // Pause/Resume
                IconButton(
                    systemImage: playbackManager.isPaused ? "play.fill" : "pause.fill",
                    label: playbackManager.isPaused ? "Resume" : "Pause",
                    action: { playbackManager.togglePause() }
                )
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.4 : 1.0)

                // Skip
                IconButton(
                    systemImage: "forward.fill",
                    label: "Skip",
                    action: { playbackManager.skip() }
                )
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.4 : 1.0)

                // Hide (skip and don't show again)
                IconButton(
                    systemImage: "eye.slash.fill",
                    label: "Hide",
                    action: { playbackManager.hide() }
                )
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.4 : 1.0)
            }

            // Speed slider
            SpeedSliderView(speed: Binding(
                get: { playbackManager.globalSpeed },
                set: { playbackManager.globalSpeed = $0 }
            ))
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.4 : 1.0)
        }
        .padding(.vertical, 8)
    }
}

@available(macOS 11.0, *)
struct PlaybackSectionView_Previews: PreviewProvider {
    static var previews: some View {
        PlaybackSectionView(playbackManager: PlaybackManager.shared)
            .padding()
            .frame(width: 280)
    }
}
