//
//  DisplayPreviewView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 13/02/2026.
//

import SwiftUI

struct DisplayPreviewView: NSViewRepresentable {
    /// Changing this value forces SwiftUI to call updateNSView, triggering a redraw.
    var refreshID: UUID
    var onScreenToggled: (() -> Void)?

    func makeNSView(context: Context) -> DisplayView {
        let view = DisplayView(frame: .zero)
        view.onScreenToggled = { onScreenToggled?() }
        return view
    }

    func updateNSView(_ nsView: DisplayView, context: Context) {
        nsView.onScreenToggled = { onScreenToggled?() }
        nsView.needsDisplay = true
    }
}
