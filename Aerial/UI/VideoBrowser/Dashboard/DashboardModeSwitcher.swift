//
//  DashboardModeSwitcher.swift
//  Aerial Companion
//
//  Header control that names the current viewing mode and changes it on the
//  fly. Reuses the same mode rows as the Displays settings panel, but routes
//  the change through `DashboardModel.applyViewingModeChange` so live
//  playback is reconfigured (not just the pref written).
//

import SwiftUI

struct DashboardModeSwitcher: View {
    /// Current mode (read fresh each render from the model so the control
    /// reflects external changes too).
    let current: ViewingMode
    let onChange: (ViewingMode) -> Void

    var body: some View {
        Picker("", selection: Binding(get: { current }, set: { onChange($0) })) {
            Label("Independent", systemImage: "display").tag(ViewingMode.independent)
            Label("Cloned", systemImage: "rectangle.on.rectangle").tag(ViewingMode.cloned)
            Label("Spanned", systemImage: "rectangle.split.2x1").tag(ViewingMode.spanned)
            Label("Mirrored", systemImage: "rectangle.2.swap").tag(ViewingMode.mirrored)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .tint(.aerial)
        .help("Change how videos are shown across your displays")
    }
}
