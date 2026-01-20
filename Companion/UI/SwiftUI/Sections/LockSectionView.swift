//
//  LockSectionView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

/// Prominent lock screen button section at the top of the popover
@available(macOS 11.0, *)
struct LockSectionView: View {
    @ObservedObject var playbackManager: PlaybackManager
    var onDismiss: () -> Void

    var body: some View {
        HStack {
            Button(action: {
                playbackManager.startScreensaver()
                onDismiss()
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.display")
                        .font(.system(size: 24, weight: .medium))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lock Screen")
                            .font(.headline)
                        Text("Start screensaver")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .background(Color.accentColor.opacity(0.1))
            .cornerRadius(8)
        }
    }
}

@available(macOS 11.0, *)
struct LockSectionView_Previews: PreviewProvider {
    static var previews: some View {
        LockSectionView(
            playbackManager: PlaybackManager.shared,
            onDismiss: {}
        )
        .padding()
        .frame(width: 280)
    }
}
