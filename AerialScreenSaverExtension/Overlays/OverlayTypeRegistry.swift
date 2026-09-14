//
//  OverlayTypeRegistry.swift
//  AerialScreenSaverExtension
//
//  Static registry mapping OverlayKind to its provider type.
//

import SwiftUI

struct OverlayTypeRegistry {

    private static var providers: [OverlayKind: any OverlayTypeProvider.Type] = [:]

    /// Register all built-in providers. Called at startup.
    static func registerAll() {
        register(ClockOverlayProvider.self)
        register(DateOverlayProvider.self)
        register(LocationOverlayProvider.self)
        register(WeatherOverlayProvider.self)
        register(MusicOverlayProvider.self)
        register(MessageOverlayProvider.self)
        register(TimerOverlayProvider.self)
        register(CountdownOverlayProvider.self)
        register(BatteryOverlayProvider.self)
        register(VerticalSpacerOverlayProvider.self)
    }

    static func register(_ provider: any OverlayTypeProvider.Type) {
        providers[provider.kind] = provider
    }

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
