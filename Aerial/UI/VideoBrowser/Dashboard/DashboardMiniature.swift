//
//  DashboardMiniature.swift
//  Aerial Companion
//
//  SwiftUI wrapper around the AppKit `DisplayView`, in its additive
//  "dashboard mode": draws the full display arrangement with the current
//  video projected across it. Used by the shared-mode (cloned / spanned /
//  mirrored) Dashboard card. Mirrors `DisplayPreviewView`, but display-only
//  (no click-to-toggle) and fed a video thumbnail instead of stock shots.
//

import SwiftUI

struct DashboardMiniature: NSViewRepresentable {
    /// Current video thumbnail to project. Cloned/mirrored paint it on each
    /// screen; spanned tiles it across the arrangement.
    var image: NSImage?
    /// Bumped when the projected image changes to force a redraw.
    var refreshID: UUID

    func makeNSView(context: Context) -> DisplayView {
        let view = DisplayView(frame: .zero)
        view.isDashboardMode = true
        view.onScreenToggled = nil
        view.dashboardImage = image
        return view
    }

    func updateNSView(_ nsView: DisplayView, context: Context) {
        nsView.isDashboardMode = true
        nsView.dashboardImage = image
        nsView.needsDisplay = true
    }
}
