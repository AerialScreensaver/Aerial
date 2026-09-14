//
//  NowPlayingSectionView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 14/02/2026.
//
//  Thin menubar-popover wrapper over the shared `PlaybackSelectorView`.
//  The selection logic now lives in `PlaybackSelectorModel` (scope:
//  `.popover`), shared with the Dashboard's per-screen picker. Only the
//  popover-specific re-sync hooks live here.
//

import SwiftUI

struct NowPlayingSectionView: View {
    @ObservedObject var playbackManager: PlaybackManager
    @StateObject private var model: PlaybackSelectorModel

    init(playbackManager: PlaybackManager) {
        _playbackManager = ObservedObject(wrappedValue: playbackManager)
        _model = StateObject(wrappedValue: PlaybackSelectorModel(scope: .popover, playbackManager: playbackManager))
    }

    var body: some View {
        PlaybackSelectorView(model: model)
            // The popover scope follows the screen the popover is shown on.
            .onChange(of: playbackManager.popoverScreenUUID) { _ in model.reloadState() }
            // AppKit posts this every time the menubar popover is about to
            // show — guarantees a re-sync from prefs on each appearance even
            // if SwiftUI throttled the Combine subscription while hidden.
            .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in
                model.reloadState()
            }
    }
}

struct NowPlayingSectionView_Previews: PreviewProvider {
    static var previews: some View {
        NowPlayingSectionView(playbackManager: PlaybackManager.shared)
            .padding()
            .frame(width: 380, height: 300)
    }
}
