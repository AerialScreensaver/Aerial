//
//  InspectorPanelView.swift
//  Aerial
//
//  SwiftUI view hosted in the inspector NSPanel.
//  Observes selectedInstanceID and renders OverlaySettingsPane for the selected overlay.
//

import SwiftUI

struct InspectorPanelView: View {
    @ObservedObject var state: OverlayEditorState

    var body: some View {
        Group {
            if let id = state.selectedInstanceID,
               let binding = state.bindingForInstance(id: id) {
                OverlaySettingsPane(state: state, instance: binding)
                    .id(id)
            } else {
                LayoutSettingsPane(state: state)
            }
        }
        .frame(minWidth: 300, maxWidth: 300, minHeight: 580, maxHeight: .infinity)
        .tint(.aerial)
    }
}
