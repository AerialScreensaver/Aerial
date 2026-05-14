//
//  GlobalSearchSourceCard.swift
//  Aerial Companion
//
//  Per-source result card for the Video Library global search.
//  Renders two shapes depending on the group's backing:
//   - `.installed`: live Source + AerialVideo grid, identical to the
//     long-standing layout (VideoBrowserCardView cells).
//   - `.available`: an Expansion the user hasn't installed yet, with
//     an ExpansionAsset grid showing read-only metadata thumbnails
//     plus an "Open in Expansions" jump button in the header.
//

import SwiftUI

struct GlobalSearchSourceCard: View {
    let group: VideoBrowserState.GlobalSearchSourceGroup
    @ObservedObject var state: VideoBrowserState

    private static let columns = [GridItem(.adaptive(minimum: 200, maximum: 200), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: sourceIcon)
                    .font(.system(size: 18))
                Text(group.displayName)
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                if case .available = group.backing {
                    openInExpansionsButton
                }
                if group.showsInstallBadge {
                    installedBadge
                }
            }

            if !group.displayDescription.isEmpty {
                Text(group.displayDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            grid
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    @ViewBuilder
    private var grid: some View {
        switch group.backing {
        case .installed(_, let videos):
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                ForEach(videos, id: \.id) { video in
                    VideoBrowserCardView(video: video, state: state, isCurrent: false)
                }
            }
        case .available(_, let assets):
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                ForEach(assets, id: \.id) { asset in
                    ExpansionAssetCardView(asset: asset)
                }
            }
        }
    }

    /// Trailing bordered button shown on available (uninstalled)
    /// expansion groups. Routes the user to the Expansions tab,
    /// scrolled to that pack's install card.
    @ViewBuilder
    private var openInExpansionsButton: some View {
        if case .available(let expansion, _) = group.backing {
            Button {
                state.routeToExpansion(id: expansion.id)
            } label: {
                Label("Open in Expansions", systemImage: "arrow.right.circle.fill")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    /// Right-aligned pill showing whether the source is installed.
    /// Available expansion groups get the orange variant. Sized to
    /// match the bordered "Open in Expansions" button so the two
    /// align flush in the header.
    private var installedBadge: some View {
        let tint: Color = group.isInstalled ? .green : .orange
        return HStack(spacing: 6) {
            Image(systemName: group.isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.system(size: 13, weight: .semibold))
            Text(group.isInstalled ? "Installed" : "Available")
                .font(.system(size: 14, weight: .medium))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Capsule().fill(tint.opacity(0.15)))
        .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5))
    }

    /// Icon parallels what the sidebar uses for that source's row.
    private var sourceIcon: String {
        switch group.backing {
        case .installed(let source, _):
            switch source.name {
            case "My Videos":  return "folder"
            case "Live Feeds": return "dot.radiowaves.left.and.right"
            default:           return "tray"
            }
        case .available:
            return "sparkles"
        }
    }
}
