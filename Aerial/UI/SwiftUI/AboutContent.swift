//
//  AboutContent.swift
//  Aerial Companion
//
//  Single source of truth for the "About Aerial" surface. Used by:
//   - `InfoWindowController` (the standalone About window opened from
//     the popover's info-circle button).
//   - `AboutSettingsPanel` (the About entry in Settings; this view sits
//     inside its "About Aerial" GroupBox).
//
//  Vertical centered hero: icon → title → version → description →
//  tinted support card with Ko-fi CTA → Website / Discord row → tiny
//  Inferno design credit footer.
//

import SwiftUI
import AppKit

struct AboutContent: View {
    @Environment(\.openWindow) private var openWindow

    private enum AboutLinks {
        static let kofi      = URL(string: "https://ko-fi.com/A0A32385Y")!
        static let website   = URL(string: "https://aerialscreensaver.github.io/")!
        static let discord   = URL(string: "https://discord.gg/TPuA5WG")!
        static let inferno   = URL(string: "https://infernodesign.com")!
    }

    /// Pulled live so the same view shows up correctly in InfoView's
    /// hosting controller AND in the Settings panel.
    private var versionLine: String {
        let marketing = Helpers.version
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "Version \(marketing) (\(build))"
    }

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)

            VStack(spacing: 4) {
                Text("Aerial")
                    .font(.system(size: 32, weight: .bold))
                Text(versionLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text("A free, open-source macOS screen saver and video wallpaper app, made and maintained by Guillaume Louel.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            supportCard

            VStack(spacing: 8) {
                Text("Looking for support?")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        NSWorkspace.shared.open(AboutLinks.website)
                    } label: {
                        Label("Website", systemImage: "globe")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        NSWorkspace.shared.open(AboutLinks.discord)
                    } label: {
                        Label("Discord", systemImage: "message")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

            Link("Icon by Inferno design", destination: AboutLinks.inferno)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 380)
    }

    private var supportCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enjoying Aerial?")
                .font(.system(size: 15, weight: .semibold))

            Text("Want to support Aerial's development? You can buy me a coffee, or check out the Expansions — the video artists share back to the project too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button {
                    NSWorkspace.shared.open(AboutLinks.kofi)
                } label: {
                    if let kofi = NSImage(named: "kofi1") {
                        Image(nsImage: kofi)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 40)
                    } else {
                        Text("Support on Ko-fi")
                    }
                }
                .buttonStyle(.plain)
                .help("Support on Ko-fi")
                .accessibilityLabel("Support on Ko-fi")
                Spacer()
            }
            .padding(.top, 4)

            HStack {
                Spacer()
                Button {
                    browseExpansions()
                } label: {
                    Label("Browse Expansions", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.aerial.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.aerial.opacity(0.30), lineWidth: 0.5)
        )
    }

    /// Open the Video Library window and select the Expansions
    /// category. Uses the deferred-static pattern so a fresh window
    /// init lands directly on Expansions; the matching notification
    /// covers the case where the window is already open.
    private func browseExpansions() {
        VideoBrowserState.pendingInitialCategory = .expansions
        openWindow(id: "videoBrowser")
        // Defer to the next runloop tick so a brand-new window's
        // SwiftUI body has time to mount its `.onReceive` observer
        // before we post — otherwise an already-open path is the
        // only path covered.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: VideoBrowserState.openCategoryRequest,
                object: BrowseCategory.expansions
            )
        }
    }
}

struct AboutContent_Previews: PreviewProvider {
    static var previews: some View {
        AboutContent()
    }
}
