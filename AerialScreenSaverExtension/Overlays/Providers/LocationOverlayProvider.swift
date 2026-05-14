//
//  LocationOverlayProvider.swift
//  AerialScreenSaverExtension
//
//  Provider for location overlay type.
//

import SwiftUI

struct LocationOverlayProvider: OverlayTypeProvider {
    static let kind: OverlayKind = .location

    static func makeView(instance: OverlayInstance, state: OverlayState) -> AnyView {
        AnyView(LocationOverlayContent(instance: instance, state: state))
    }

    static func makeSettingsView(instance: Binding<OverlayInstance>) -> AnyView {
        AnyView(LocationSettingsContent(instance: instance))
    }
}

private struct LocationOverlayContent: View {
    let instance: OverlayInstance
    @ObservedObject var state: OverlayState

    var body: some View {
        let text = state.locationText ?? (state.isPreview ? "San Francisco, California" : "Location")

        if state.locationVisible || state.isPreview {
            Text(text)
                .font(overlayFont(for: instance))
        }
    }
}

private struct LocationSettingsContent: View {
    @Binding var instance: OverlayInstance

    private var time: String {
        instance.typeSettings["time"]?.asString ?? "always"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Display", selection: Binding(
                get: { time },
                set: { instance.typeSettings["time"] = .string($0) }
            )) {
                Text("Always").tag("always")
                Text("10 seconds").tag("tenSeconds")
            }
        }
    }
}
