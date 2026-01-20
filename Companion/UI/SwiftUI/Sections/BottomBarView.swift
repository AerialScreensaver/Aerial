//
//  BottomBarView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

/// Bottom bar with info, settings, help buttons and version label
@available(macOS 11.0, *)
struct BottomBarView: View {
    let version: String
    var onOpenInfo: () -> Void
    var onOpenSettings: () -> Void
    var onOpenHelp: () -> Void
    var onExit: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Info button
            Button(action: onOpenInfo) {
                Image(systemName: "info.circle")
                    .font(.system(size: 25))
            }
            .buttonStyle(.borderless)
            .help("About Aerial")

            // Settings button
            Button(action: onOpenSettings) {
                Image(systemName: "list.bullet.circle")
                    .font(.system(size: 25))
            }
            .buttonStyle(.borderless)
            .help("Companion Settings")

            // Help button
            Button(action: onOpenHelp) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 25))
            }
            .buttonStyle(.borderless)
            .help("Help")

            Spacer()

            // Version label
            Text(version)
                .font(.headline)
                .foregroundColor(.secondary)

            Spacer()

            // Exit button
            Button(action: onExit) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 25))
            }
            .buttonStyle(.borderless)
            .help("Quit Aerial Companion")
        }
        .padding(.top, 8)
    }
}

@available(macOS 11.0, *)
struct BottomBarView_Previews: PreviewProvider {
    static var previews: some View {
        BottomBarView(
            version: "Aerial 3.5",
            onOpenInfo: {},
            onOpenSettings: {},
            onOpenHelp: {},
            onExit: {}
        )
        .padding()
        .frame(width: 380)
    }
}
