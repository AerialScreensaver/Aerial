//
//  GlobalSearchResultsView.swift
//  Aerial Companion
//
//  Container for the cross-source global search results in the
//  Video Library. Renders one `GlobalSearchSourceCard` per source
//  with matching videos, sorted by priority (downloaded matches >
//  installed-but-not-downloaded > available expansions).
//
//  Two call sites:
//   - `VideoGridView` appends this below its own filtered grid when
//     search is active, passing `excludedSource` so the current
//     source isn't duplicated.
//   - `VideoBrowserView.contentView` routes here directly when
//     search is active and the current sidebar item doesn't support
//     the in-category filter (Now Playing, Live Feeds, User
//     Playlist, Expansions).
//

import SwiftUI

struct GlobalSearchResultsView: View {
    @ObservedObject var state: VideoBrowserState
    /// Source name to omit from the global section. `nil` means
    /// include every source. `VideoGridView` passes its
    /// `currentSourceName` so the grid doesn't show duplicate cards.
    var excludedSource: String? = nil
    /// When true, prefix the results with a small "Other sources"
    /// header — used by `VideoGridView` to differentiate the
    /// global section from its own filtered grid above.
    var showOtherSourcesHeader: Bool = false

    var body: some View {
        let groups = state.globalSearchGroups(excluding: excludedSource)

        if groups.isEmpty {
            emptyState
        } else {
            LazyVStack(alignment: .leading, spacing: 16) {
                if showOtherSourcesHeader {
                    Text("Other sources")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                ForEach(groups) { group in
                    GlobalSearchSourceCard(group: group, state: state)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No matches for \"\(state.searchText)\"")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}
