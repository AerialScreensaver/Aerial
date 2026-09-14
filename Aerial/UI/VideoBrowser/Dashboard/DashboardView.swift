//
//  DashboardView.swift
//  Aerial Companion
//
//  Root of the Video Library Dashboard — the default landing view. In
//  independent viewing mode it renders one card per display; in shared
//  modes (cloned / spanned / mirrored) it renders a single unified card.
//
//  Built self-contained (owns its `DashboardModel`) so it can later be
//  hosted standalone as the basis for a "dock mode" single-window app.
//

import SwiftUI

struct DashboardView: View {
    /// The browser state is held so later phases (mode switch) can nudge
    /// `refreshTrigger` to re-render the sidebar's mode-dependent rows.
    @ObservedObject var state: VideoBrowserState
    @StateObject private var model = DashboardModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ContentHeader(
                    icon: "house",
                    title: "Home",
                    description: model.modeDescription(model.viewingMode)
                ) {
                    DashboardModeSwitcher(current: model.viewingMode) { newMode in
                        model.applyViewingModeChange(newMode)
                        // The sidebar's PLAYLIST rows read PrefsDisplays.viewingMode
                        // un-observed, so nudge the browser state to re-render them.
                        state.refreshTrigger += 1
                    }
                }

                DashboardRecapStrip(model: model, playbackManager: model.playbackManager)

                // System integration: start-the-screensaver and live
                // wallpaper-extension controls (status-channel driven).
                DashboardSystemRow()

                // Independent + common overlays: one global overlay row for
                // all the per-display cards. (Per-screen overlays surface a
                // row inside each card; shared viewing modes surface it in
                // the single shared card.)
                if model.isIndependent && !model.overlayPerScreen {
                    DashboardOverlayStatusRow(screenUUID: nil, perScreen: false)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                }

                if model.isIndependent {
                    ForEach(model.screenInfos) { screen in
                        DashboardScreenCard(screen: screen, model: model)
                    }
                } else {
                    DashboardSharedCard(model: model)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
