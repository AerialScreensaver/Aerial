//
//  ExpansionCard.swift
//  Aerial Companion
//
//  Single card on the Expansions page. Layout: ~320×180 screenshot on
//  the left, then name / author / badges / description / actions on
//  the right. Free packs get a one-click Install; paid packs only get
//  Visit site (no prices in-app). The green Installed chip surfaces
//  when the matching source is already in `SourceList.list`.
//

import SwiftUI
import AppKit

struct ExpansionCard: View {
    let expansion: Expansion
    let isInstalled: Bool
    let onInstall: () -> Void
    let onVisitSite: () -> Void
    /// Optional: when set, a floating arrow appears in the bottom-right
    /// of the thumbnail and invokes this closure when tapped. Used to
    /// jump from the showcase straight into the pack's video list. Only
    /// passed in when the pack is installed.
    var onOpenCategory: (() -> Void)?

    /// `true` when the user has Increase Contrast on (System Settings →
    /// Accessibility → Display). Subtle 0.15-opacity tints become
    /// invisible there, so the tier pill and card border switch to
    /// saturated / opaque variants.
    @Environment(\.colorSchemeContrast) private var contrast
    private var highContrast: Bool { contrast == .increased }

    /// Subscribe to download-queue state so the per-source status
    /// line under the "Installed" pill re-renders as videos move
    /// through the queue (queued → downloading → cached).
    @ObservedObject private var downloadTracker = DownloadTracker.shared

    private static let thumbSize = CGSize(width: 230, height: 130)

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            screenshot
                .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                // Expand the click target from the small floating arrow
                // button to the whole thumbnail when the pack is
                // installed (i.e. `onOpenCategory` is non-nil). The
                // arrow button still sits on top in the .overlay below
                // and captures clicks in its own 32×32 region.
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onTapGesture {
                    onOpenCategory?()
                }
                .onHover { hovering in
                    guard onOpenCategory != nil else { return }
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .help(onOpenCategory != nil ? "Open in library" : "")
                .overlay(openCategoryButton, alignment: .bottomTrailing)

            VStack(alignment: .leading, spacing: 8) {
                // Title row: name+author left, "Installed" pill pushed
                // to the top-right of the card content. Inline (not an
                // overlay) so it never collides with a long title.
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(expansion.name)
                            .font(.title3.bold())
                        Text(expansion.author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if isInstalled {
                        VStack(alignment: .trailing, spacing: 4) {
                            installedBadge
                            downloadStatusText
                        }
                    }
                }

                badges

                Text(expansion.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(highContrast ? Color.primary.opacity(0.6)
                                     : Color.secondary.opacity(0.18),
                        lineWidth: highContrast ? 1 : 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Screenshot

    @ViewBuilder
    private var screenshot: some View {
        if let url = URL(string: expansion.screenshotURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    placeholder
                case .empty:
                    placeholder.overlay(ProgressView().controlSize(.small))
                @unknown default:
                    placeholder
                }
            }
            .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
            .background(Color.black)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color.aerial.opacity(0.4), Color.aerial.opacity(0.15)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - Badges (tier + optional 240 FPS marker)

    private var badges: some View {
        HStack(spacing: 6) {
            tierBadge
            if expansion.is240fps == true {
                fpsBadge
            }
        }
    }

    private var fpsBadge: some View {
        badgePill(text: "240 FPS",
                  fg: Color.aerial,
                  bg: Color.aerial.opacity(0.15),
                  stroke: Color.aerial.opacity(0.35))
    }

    private var tierBadge: some View {
        Group {
            switch expansion.tier {
            case .free:
                tierBadgePill(text: "Free", icon: "heart.fill", tint: Color.pink)
            case .paid:
                tierBadgePill(text: "Paid", icon: "cart.fill", tint: Color.orange)
            }
        }
    }

    /// Tier pill with a leading SF Symbol so the Free / Paid partition
    /// is differentiable without relying on hue alone (Deuteranopia /
    /// Protanopia safety). Switches to a saturated solid + white text
    /// when Increase Contrast is on.
    private func tierBadgePill(text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundColor(highContrast ? .white : tint)
        .background(Capsule().fill(highContrast ? tint : tint.opacity(0.15)))
        .overlay(Capsule().stroke(highContrast ? tint : tint.opacity(0.35),
                                  lineWidth: highContrast ? 1 : 0.5))
    }

    private func badgePill(text: String, fg: Color, bg: Color, stroke: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundColor(fg)
            .background(Capsule().fill(bg))
            .overlay(Capsule().stroke(stroke, lineWidth: 0.5))
    }

    // MARK: - Jump-to-category button (bottom-right of thumbnail)

    /// Floating circular button overlaid on the thumbnail that takes
    /// the user from the showcase directly to the pack's filtered
    /// video list. Only rendered when an `onOpenCategory` closure has
    /// been provided — i.e. when the pack is installed and there's
    /// somewhere to jump to. Dark semi-opaque disc with a white
    /// arrow so it reads on bright or dark hero images.
    @ViewBuilder
    private var openCategoryButton: some View {
        if let onOpenCategory {
            Button {
                onOpenCategory()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.55))
                    Circle()
                        .stroke(Color.white.opacity(0.7), lineWidth: 1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 32, height: 32)
                .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
            }
            .buttonStyle(.plain)
            .padding(8)
            .help("Open in library")
            .accessibilityLabel("Open in library")
            .accessibilityHint("Switches the Video Library sidebar to this expansion")
        }
    }

    // MARK: - Installed pill (top-right of card content)

    /// Aerial-tinted capsule with a bold white check + "Installed".
    /// Lives at the top-right of the card content row so it sits in
    /// the same spot for every installed pack and never collides with
    /// a long title (the title row is an HStack with a Spacer between
    /// title and pill).
    private var installedBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
            Text("Installed")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.aerial))
        .shadow(color: .black.opacity(0.18), radius: 1.5, x: 0, y: 1)
        .accessibilityLabel("Installed")
    }

    // MARK: - Download status

    /// Counts for this expansion's source, recomputed each render so
    /// the UI stays in sync via `@ObservedObject downloadTracker`.
    /// Returns `nil` while VideoList hasn't caught up to a freshly-
    /// installed source (post-install entries.json fetch race) so the
    /// card can hide the status until counts are real.
    private struct DownloadCounts {
        let total: Int
        let downloaded: Int
        let inFlight: Bool
    }

    private var downloadCounts: DownloadCounts? {
        let sourceName = expansion.sourceName
        let sourceVideos = VideoList.instance.videos.filter { $0.source.name == sourceName }
        guard !sourceVideos.isEmpty else { return nil }
        let downloaded = sourceVideos.filter { $0.isAvailableOffline }.count
        let activeIds = Set(VideoManager.sharedInstance.queuedVideoIds)
        let inFlight = sourceVideos.contains { activeIds.contains($0.id) }
        return DownloadCounts(total: sourceVideos.count, downloaded: downloaded, inFlight: inFlight)
    }

    /// Compact text-only status line that sits under the "Installed"
    /// pill in the title row. Three states: all-done checkmark,
    /// downloading-with-spinner, or "Downloaded N/M".
    @ViewBuilder
    private var downloadStatusText: some View {
        if let c = downloadCounts {
            if c.downloaded == c.total {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Text("Downloaded")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if c.inFlight {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Downloading \(c.downloaded)/\(c.total)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Downloaded \(c.downloaded)/\(c.total)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The Download CTA that lives in the actions row (alongside Visit
    /// site). Renders only when the pack is installed AND idle AND
    /// some videos are still missing. Sized `.large` to match the
    /// other action buttons.
    @ViewBuilder
    private var downloadAllButton: some View {
        if isInstalled,
           let c = downloadCounts,
           !c.inFlight,
           c.downloaded < c.total {
            Button {
                DownloadCoordinator.shared.enqueueAllVideos(forSource: expansion.sourceName)
            } label: {
                Label("Download All (\(c.total - c.downloaded))", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            Spacer()

            // Installed packs with missing videos get a Download All
            // CTA next to Visit site. Renders only when partial + idle.
            downloadAllButton

            // Free + has manifestURL = one-click install (when not installed)
            if expansion.tier == .free, !isInstalled, expansion.manifestURL != nil {
                Button {
                    onInstall()
                } label: {
                    Label("Install", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            // Paid: always show Visit site so users can purchase / download
            // updates. Free + installed: same — still useful for release
            // notes etc.
            Button {
                onVisitSite()
            } label: {
                Label("Visit site", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}
