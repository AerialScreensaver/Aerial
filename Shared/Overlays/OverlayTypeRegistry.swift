//
//  OverlayTypeRegistry.swift
//  Aerial
//
//  Static registry mapping OverlayKind to its provider type.
//

import SwiftUI

struct OverlayTypeRegistry {

    /// The built-in providers, keyed by kind. Immutable: a table that is
    /// filled once at startup and read from every render is shared state
    /// with no writer to protect — so it is not mutable at all.
    private static let providers: [OverlayKind: any OverlayTypeProvider.Type] = {
        let all: [any OverlayTypeProvider.Type] = [
            ClockOverlayProvider.self,
            DateOverlayProvider.self,
            LocationOverlayProvider.self,
            WeatherOverlayProvider.self,
            MusicOverlayProvider.self,
            MessageOverlayProvider.self,
            TimerOverlayProvider.self,
            CountdownOverlayProvider.self,
            BatteryOverlayProvider.self,
            VerticalSpacerOverlayProvider.self,
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })
    }()

    /// Kept for the two startup call sites; the table above is static now.
    static func registerAll() {}

    /// Render a view for an instance using its registered provider
    @ViewBuilder
    static func makeView(for instance: OverlayInstance, state: OverlayState) -> some View {
        if let provider = providers[instance.kind] {
            provider.makeView(instance: instance, state: state)
        } else {
            Text(instance.kind.displayName)
                .font(overlayFont(for: instance))
        }
    }

    /// Render a settings view for an instance using its registered provider
    @ViewBuilder
    static func makeSettingsView(for instance: Binding<OverlayInstance>) -> some View {
        if let provider = providers[instance.wrappedValue.kind] {
            provider.makeSettingsView(instance: instance)
        } else {
            Text("No settings available")
                .foregroundStyle(.secondary)
        }
    }
}
