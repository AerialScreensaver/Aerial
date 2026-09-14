//
//  VideoBrowserView.swift
//  Aerial Companion
//
//  Top-level NavigationSplitView for the Video Browser. The
//  NavigationSplitView is essential — AppKit detects the SwiftUI
//  sidebar column and overlays the traffic lights on it (the macOS 26
//  Tahoe look). Search field and view-mode toggle are routed through
//  SwiftUI's `.searchable` and `.toolbar` APIs, which target the real
//  NSToolbar attached on the window controller side.
//

import SwiftUI

struct VideoBrowserView: View {
    @StateObject private var state = VideoBrowserState()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            VideoBrowserSidebar(state: state)
                // The sidebar-toggle item is added to the sidebar
                // column's toolbar slot — `.toolbar(removing:)` only
                // takes effect when applied to that column, not the
                // NavigationSplitView root.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            HSplitView {
                contentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if state.hasMultiSelection {
                    MultiSelectionInspectorView(state: state)
                        .frame(width: 300)
                } else if let video = state.selectedVideo {
                    VideoInspectorView(video: video, state: state)
                        .frame(width: 300)
                }
            }
            // `.searchable` and `.toolbar` attached to the detail
            // (rather than the NavigationSplitView root) land the
            // items in the detail column's trailing toolbar slot —
            // top-right of the window — instead of the sidebar.
            .searchable(text: $state.searchText, prompt: "Search videos…")
            .modifier(MinimizedSearchToolbar())
            .toolbar {
                // Centered Spacer eats the flexible toolbar space so
                // both `.primaryAction` items and the `.searchable`
                // field land trailing (right) instead of leading. Same
                // trick used by the Settings window.
                ToolbarItem(placement: .principal) {
                    Spacer()
                }
                if state.supportsViewMode {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: {
                            state.viewMode = state.viewMode == .grid ? .list : .grid
                        }) {
                            Image(systemName: state.viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                        }
                        .help(state.viewMode == .grid ? "Switch to list" : "Switch to grid")
                        .accessibilityLabel(state.viewMode == .grid ? "Switch to list" : "Switch to grid")
                    }
                }
                // Sits immediately to the left of the .searchable field
                // (search lands trailing-most; primaryAction items
                // appear before it in declaration order). `Label` with
                // `.titleAndIcon` forces both icon and text regardless
                // of the toolbar's display mode.
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        SettingsWindowController.show(via: openWindow)
                    }) {
                        Label("Settings", systemImage: "gear")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Open Settings")
                    .accessibilityLabel("Open Settings")
                }
            }
        }
        // Sidebar-toggle and title removal must be applied to the
        // NavigationSplitView root — they're root-level toolbar items
        // managed by the split-view container, not the detail.
        .toolbar(removing: .title)
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 550)
        .tint(.aerial)
        // External routing: callers (e.g. About box's "Browse
        // Expansions") post `openCategoryRequest` after openWindow to
        // jump an already-open Video Library to a specific sidebar
        // category. Clears the search field first so the content view
        // routes to that category instead of staying on global search
        // results.
        .onReceive(NotificationCenter.default.publisher(for: VideoBrowserState.openCategoryRequest)) { note in
            guard let category = note.object as? BrowseCategory else { return }
            state.searchText = ""
            state.selectedSidebarItem = category
        }
    }

    // MARK: - Content Routing

    @ViewBuilder
    private var contentView: some View {
        // Active search in a non-searchable category replaces the
        // bespoke view with global cross-source results. Searchable
        // categories handle the global section themselves (appended
        // below their own filtered grid in `VideoGridView`).
        if !state.searchText.isEmpty && !state.supportsViewMode {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GlobalSearchResultsView(state: state)
                }
                .padding(16)
            }
        } else if state.isNowPlaying {
            PlaylistSummaryView(state: state)
        } else if state.isUserPlaylist {
            UserPlaylistContentView(state: state)
        } else if state.isLiveFeeds {
            LiveFeedsContentView()
        } else if state.isExpansions {
            ExpansionsContentView(state: state)
        } else if state.isActivity {
            ActivityContentView(state: state)
        } else {
            VideoGridView(state: state)
        }
    }
}

/// Opts the `.searchable` field into the macOS 26 collapsed-by-default
/// behavior — a small magnifier icon in the toolbar that expands to a
/// full search field on click. Without this on macOS 26+, the
/// `.searchable` field renders at full width across the detail's
/// toolbar region, which sprawls and looks unbalanced. No-op on
/// earlier macOS where the modifier doesn't exist.
private struct MinimizedSearchToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.searchToolbarBehavior(.automatic)
        } else {
            content
        }
    }
}

struct VideoBrowserView_Previews: PreviewProvider {
    static var previews: some View {
        VideoBrowserView()
            .frame(width: 1000, height: 600)
    }
}
