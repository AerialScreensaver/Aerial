//
//  OverlayEditorView.swift
//  Aerial
//
//  Full-bleed preview with HUD toolbar overlay. Palette and settings are external panels/popovers.
//

import SwiftUI

struct OverlayEditorView: View {
    @ObservedObject var state: OverlayEditorState
    @StateObject private var overlayState = OverlayState(isPreview: true)

    var body: some View {
        ZStack {
            // Video background (full bleed)
            VideoPreviewLayer(url: state.previewVideoURL)

            // Rendered overlays (inline drop zones appear during drag)
            OverlayPreviewRenderer(state: state, overlayState: overlayState)

            // HUD toolbar anchored to top
            OverlayEditorToolbar(state: state) {
                state.showPalette = false
                state.onCloseEditor?()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .tint(.aerial)
        .simultaneousGesture(TapGesture().onEnded {
            state.deselect()
        })
        .onAppear {
            OverlayTypeRegistry.registerAll()
        }
    }
}
