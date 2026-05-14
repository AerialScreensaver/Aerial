//
//  UpdateAvailableBarView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 03/04/2026.
//

import SwiftUI

/// Orange notification bar shown when a Sparkle update is available
struct UpdateAvailableBarView: View {
    var isReadyToInstall: Bool
    var onInstall: () -> Void

    var body: some View {
        HStack {
            Text("A new version of Aerial is available")
                .font(.system(size: 13, weight: .medium))

            Spacer()

            Button(action: onInstall) {
                if isReadyToInstall {
                    Label("Install & Restart", systemImage: "arrow.clockwise")
                } else {
                    Label("Update", systemImage: "arrow.down.circle")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(8)
    }
}

struct UpdateAvailableBarView_Previews: PreviewProvider {
    static var previews: some View {
        UpdateAvailableBarView(isReadyToInstall: false, onInstall: {})
            .padding()
            .frame(width: 300)
    }
}
