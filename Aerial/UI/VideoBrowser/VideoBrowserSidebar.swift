//
//  VideoBrowserSidebar.swift
//  Aerial Companion
//
//  Sidebar for the Video Browser: Playlist + Browse sections.
//

import SwiftUI

struct VideoBrowserSidebar: View {
    @ObservedObject var state: VideoBrowserState
    @State private var expansionsExpanded: Bool = false
    /// Stable IDs for the orange "New" pills the sidebar can display.
    /// The raw value is what's persisted in `companion.json` — change
    /// it and you'll re-show the badge to existing users.
    private enum NewBadgeID: String {
        case expansions
        case liveFeeds
        case myVideos
    }

    /// Local mirror of `Preferences.dismissedNewBadges` so the view
    /// re-renders when the user dismisses a badge. Hydrated at view
    /// init; mutations go through `dismissNewBadge(_:)` which writes
    /// both the @State and Preferences.
    @State private var dismissedNewBadges: Set<String> = Set(Preferences.dismissedNewBadges)

    /// Increase Contrast preference — when on, the sidebar selection
    /// pill switches from a faint Aerial tint to a saturated solid so
    /// it remains visible at high contrast.
    @Environment(\.colorSchemeContrast) private var contrast
    private var highContrast: Bool { contrast == .increased }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
            // PLAYLIST section
            Text("PLAYLIST")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

            // Independent mode: each connected display has its own
            // playlist driving its wallpaper, so we list them by name.
            // Other viewing modes (cloned / spanned / mirrored) drive
            // playback from the shared playlist — surface that single
            // row labelled by the active mode instead of a generic
            // "Now Playing".
            if PrefsDisplays.viewingMode == .independent {
                ForEach(NSScreen.screens, id: \.self) { screen in
                    let uuid = screen.screenUuid
                    sidebarRow(
                        icon: "display",
                        title: screen.localizedName,
                        category: .nowPlaying(screenUUID: uuid)
                    )
                }
            } else {
                sidebarRow(
                    icon: sharedPlaylistIcon,
                    title: sharedPlaylistTitle,
                    category: .nowPlaying(screenUUID: nil)
                )
            }

            Divider()
                .padding(.vertical, 4)
                .padding(.horizontal, 12)

            // MY PLAYLISTS section
            UserPlaylistSidebarSection(state: state)

            Divider()
                .padding(.vertical, 4)
                .padding(.horizontal, 12)

            // BROWSE section
            Text("BROWSE")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

            sidebarRow(icon: "film.stack", title: "All Videos", category: .allVideos)
            sidebarRow(icon: "folder", title: "My Videos", category: .source("My Videos"), showNewBadge: showNewBadge(.myVideos))
            sidebarRow(icon: "dot.radiowaves.left.and.right", title: "Live Feeds", category: .source("Live Feeds"), showNewBadge: showNewBadge(.liveFeeds))

            // Expansions: same DisclosureGroup widget as By Location /
            // By Source below, so the chevron looks identical. The
            // label uses the same tight HStack as `disclosureLabel`
            // (no internal padding) so the icon sits flush after the
            // system chevron, plus a selection pill so tapping the
            // row still navigates to the Expansions showcase.
            if installedExpansionSources.isEmpty {
                sidebarRow(icon: "sparkles", title: "Expansions", category: .expansions, showNewBadge: showNewBadge(.expansions))
            } else {
                DisclosureGroup(isExpanded: $expansionsExpanded) {
                    ForEach(installedExpansionSources, id: \.name) { source in
                        sidebarRow(icon: "tray", title: source.name, category: .source(source.name))
                            .padding(.leading, 12)
                    }
                } label: {
                    expansionsDisclosureLabel
                }
                .padding(.horizontal, 8)
                // When the user navigates to an installed expansion (via
                // the card's arrow / thumbnail click, or any other
                // programmatic route), open the disclosure so the
                // selected row is visible. One-way — never auto-
                // collapses; the user retains manual control of that.
                .onChange(of: state.selectedSidebarItem) { newValue in
                    if case .source(let name) = newValue,
                       installedExpansionSources.contains(where: { $0.name == name }) {
                        expansionsExpanded = true
                    }
                }
            }

            // By Location
            DisclosureGroup {
                ForEach(VideoList.instance.getSources(mode: .location), id: \.self) { loc in
                    sidebarRow(icon: "mappin", title: loc, category: .location(loc))
                        .padding(.leading, 12)
                }
            } label: {
                disclosureLabel("By Location", systemImage: "map")
            }
            .padding(.horizontal, 8)

            // By Scene
            DisclosureGroup {
                ForEach(SourceScene.allCases, id: \.self) { scene in
                    sidebarRow(icon: sceneIcon(scene), title: scene.rawValue, category: .scene(scene))
                        .padding(.leading, 12)
                }
            } label: {
                disclosureLabel("By Scene", systemImage: "photo.on.rectangle")
            }
            .padding(.horizontal, 8)

            // By Time of Day
            DisclosureGroup {
                sidebarRow(icon: "sun.max", title: "Day", category: .timeOfDay("day"))
                    .padding(.leading, 12)
                sidebarRow(icon: "sunrise", title: "Sunrise", category: .timeOfDay("sunrise"))
                    .padding(.leading, 12)
                sidebarRow(icon: "sunset", title: "Sunset", category: .timeOfDay("sunset"))
                    .padding(.leading, 12)
                sidebarRow(icon: "moon.stars", title: "Night", category: .timeOfDay("night"))
                    .padding(.leading, 12)
            } label: {
                disclosureLabel("By Time of Day", systemImage: "clock")
            }
            .padding(.horizontal, 8)

            // By Source — Apple-shipped manifests only (macOS / tvOS).
            // Community / online / installed-from-link packs live under
            // the Expansions section above instead of here.
            DisclosureGroup {
                ForEach(VideoList.instance.getSources(mode: .source).filter {
                    $0.hasPrefix("tvOS") || $0.hasPrefix("macOS")
                }, id: \.self) { src in
                    sidebarRow(icon: "tray", title: src, category: .source(src))
                        .padding(.leading, 12)
                }
            } label: {
                disclosureLabel("By Source", systemImage: "tray.2")
            }
            .padding(.horizontal, 8)

            Divider()
                .padding(.vertical, 4)
                .padding(.horizontal, 12)

            sidebarRow(icon: "arrow.down.circle", title: "Downloaded", category: .downloaded)
            sidebarRow(icon: "cloud", title: "Not Downloaded", category: .notDownloaded)
            sidebarRow(icon: "star", title: "Favorites", category: .favorites)
            sidebarRow(icon: "eye.slash", title: "Hidden", category: .hidden)

            Divider()
                .padding(.vertical, 4)
                .padding(.horizontal, 12)

            sidebarRow(icon: "clock.arrow.circlepath", title: "Activity", category: .activity)

        }
        }
        .frame(minWidth: 200, maxWidth: 220)
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: state.selectedSidebarItem) { newValue in
            switch newValue {
            case .expansions:
                dismissNewBadge(.expansions)
            case .source("My Videos"):
                dismissNewBadge(.myVideos)
            case .source("Live Feeds"):
                dismissNewBadge(.liveFeeds)
            case .source(let name) where installedExpansionSources.contains(where: { $0.name == name }):
                dismissNewBadge(.expansions)
            default:
                break
            }
        }
    }

    // MARK: - Sidebar Row

    private func sidebarRow(icon: String, title: String, category: BrowseCategory, showNewBadge: Bool = false) -> some View {
        let isSelected = state.selectedSidebarItem == category
        let highContrastSelected = isSelected && highContrast
        // Wrapped in a Button (with .buttonStyle(.plain) to keep the
        // visual identical) so the row is keyboard-focusable and
        // VoiceOver announces it as a Button rather than a static
        // tappable view. The .accessibilityAddTraits ensures the
        // selected state propagates to assistive tech.
        return Button {
            state.clearSelection()
            state.selectedSidebarItem = category
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(highContrastSelected ? .white
                                     : (isSelected ? .aerial : .secondary))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(highContrastSelected ? .white : .primary)
                if showNewBadge {
                    newBadge
                }
                Spacer()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 12)
            .background(isSelected
                        ? (highContrast ? Color.aerial : Color.aerial.opacity(0.1))
                        : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .padding(.horizontal, 4)
    }

    /// Whether the orange "New" pill for `id` should still render.
    private func showNewBadge(_ id: NewBadgeID) -> Bool {
        !dismissedNewBadges.contains(id.rawValue)
    }

    /// Dismiss `id` in both the local @State (so the view re-renders
    /// immediately) and `companion.json` via `Preferences` (so the
    /// dismissal sticks across relaunches). No-op if already dismissed.
    private func dismissNewBadge(_ id: NewBadgeID) {
        guard !dismissedNewBadges.contains(id.rawValue) else { return }
        dismissedNewBadges.insert(id.rawValue)
        Preferences.dismissNewBadge(id.rawValue)
    }

    /// Small "New" pill drawn next to a sidebar row title to flag a
    /// recently-introduced section (currently only Expansions).
    private var newBadge: some View {
        Text("New")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange))
    }

    private func disclosureLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 14))
        }
    }

    /// Mirrors `disclosureLabel` (no horizontal padding, so the icon
    /// sits flush after the system chevron) but adds the Aerial
    /// selection highlight + tap gesture so the row still navigates
    /// to the Expansions showcase.
    private var expansionsDisclosureLabel: some View {
        let isSelected = state.selectedSidebarItem == .expansions
        let highContrastSelected = isSelected && highContrast
        return HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 15))
                .foregroundColor(highContrastSelected ? .white
                                 : (isSelected ? .aerial : .secondary))
                .frame(width: 20)
            Text("Expansions")
                .font(.system(size: 14))
                .foregroundColor(highContrastSelected ? .white : .primary)
            if showNewBadge(.expansions) {
                newBadge
            }
            Spacer()
        }
        .padding(.vertical, 5)
        .background(isSelected
                    ? (highContrast ? Color.aerial : Color.aerial.opacity(0.1))
                    : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            state.clearSelection()
            state.selectedSidebarItem = .expansions
        }
    }

    /// Title shown for the shared playlist row in non-independent
    /// viewing modes — reflects the actual mode driving playback.
    private var sharedPlaylistTitle: String {
        switch PrefsDisplays.viewingMode {
        case .cloned: return "Cloned"
        case .spanned: return "Spanned"
        case .mirrored: return "Mirrored"
        case .independent: return "Now Playing"  // unused; this row is hidden in independent mode
        }
    }

    /// SF Symbol for the shared playlist row, paired with `sharedPlaylistTitle`.
    private var sharedPlaylistIcon: String {
        switch PrefsDisplays.viewingMode {
        case .cloned: return "rectangle.on.rectangle"
        case .spanned: return "rectangle.split.2x1"
        case .mirrored: return "rectangle.2.swap"
        case .independent: return "play.circle"
        }
    }

    /// Sources we treat as "installed expansions": everything in
    /// `SourceList.list` that isn't a local source, isn't the special
    /// "My Videos" / "Live Feeds" entries, and isn't an Apple-shipped
    /// `tvOS …` / `macOS …` manifest. The `state.refreshTrigger`
    /// dependency below makes the sidebar re-render when sources are
    /// added or removed.
    private var installedExpansionSources: [Source] {
        _ = state.refreshTrigger
        return SourceList.list.filter { src in
            src.type != .local
                && src.name != "My Videos"
                && src.name != "Live Feeds"
                && !src.name.hasPrefix("tvOS")
                && !src.name.hasPrefix("macOS")
        }
    }

}

struct VideoBrowserSidebar_Previews: PreviewProvider {
    static var previews: some View {
        VideoBrowserSidebar(state: PreviewData.makeState())
            .frame(height: 600)
    }
}
