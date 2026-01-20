//
//  InfoView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/01/2026.
//

import SwiftUI

/// About window content - displays app info and external links
@available(macOS 11.0, *)
struct InfoView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 25) {
            // App icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)

            // Content
            VStack(alignment: .leading, spacing: 8) {
                Text("Aerial Companion")
                    .font(.system(size: 30, weight: .semibold))

                Text("Version \(Helpers.version)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                Text("A free, open source, companion app for the Aerial macOS Screen Saver developed and maintained by Guillaume Louel.\n\nEnjoying Aerial?")
                    .font(.system(size: 13))
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)

                // Buttons
                VStack(alignment: .leading, spacing: 12) {
                    // Ko-fi donate button (larger, on its own row)
                    Button(action: openKofi) {
                        if let kofiImage = NSImage(named: "kofi1") {
                            Image(nsImage: kofiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 36)
                        } else {
                            Text("Support on Ko-fi")
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Support on Ko-fi")

                    // Secondary buttons row
                    HStack(spacing: 12) {
                        // GitHub button
                        Button(action: openGitHub) {
                            Text("Check project on GitHub")
                        }
                        .controlSize(.large)

                        // Icon credit button
                        Button(action: openInfernoDesign) {
                            if let logoImage = NSImage(named: "LogoIcon-128px") {
                                Label {
                                    Text("Icon by Inferno Design")
                                } icon: {
                                    Image(nsImage: logoImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 16, height: 16)
                                }
                            } else {
                                Text("Icon by Inferno Design")
                            }
                        }
                        .controlSize(.large)
                    }
                }
                .padding(.top, 16)
            }
        }
        .padding(30)
        .frame(minWidth: 600)
    }

    // MARK: - Actions

    private func openKofi() {
        if let url = URL(string: "https://ko-fi.com/A0A32385Y") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openGitHub() {
        if let url = URL(string: "https://github.com/glouel/AerialCompanion") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openInfernoDesign() {
        if let url = URL(string: "https://infernodesign.com") {
            NSWorkspace.shared.open(url)
        }
    }
}

@available(macOS 11.0, *)
struct InfoView_Previews: PreviewProvider {
    static var previews: some View {
        InfoView()
    }
}
