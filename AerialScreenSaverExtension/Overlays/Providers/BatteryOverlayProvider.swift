//
//  BatteryOverlayProvider.swift
//  AerialScreenSaverExtension
//
//  Provider for battery overlay type.
//

import SwiftUI

struct BatteryOverlayProvider: OverlayTypeProvider {
    static let kind: OverlayKind = .battery

    static func makeView(instance: OverlayInstance, state: OverlayState) -> AnyView {
        AnyView(BatteryOverlayContent(instance: instance, isPreview: state.isPreview))
    }

    static func makeSettingsView(instance: Binding<OverlayInstance>) -> AnyView {
        AnyView(BatterySettingsContent(instance: instance))
    }
}

private struct BatteryOverlayContent: View {
    let instance: OverlayInstance
    /// In the visual overlay editor we always render something — even when
    /// the hide rules would otherwise apply at runtime — so the user can
    /// see and drag the overlay they're configuring. Mirrors the sample-
    /// data path in Weather / Music / Location providers.
    let isPreview: Bool

    private var displayMode: String {
        instance.typeSettings["displayMode"]?.asString ?? "iconAndText"
    }

    /// Enables the "hide above <threshold>%" rule while the Mac is
    /// plugged in. Replaces the previous `hideWhenFull` toggle; old
    /// `hideWhenFull: true` entries are ignored (user re-enables via
    /// the new slider — the behaviour difference is minor since that
    /// path only fires on laptops at exactly 100 %).
    private var hideAboveEnabled: Bool {
        instance.typeSettings["hideAboveEnabled"]?.asBool ?? false
    }

    private var hideAboveThreshold: Int {
        instance.typeSettings["hideAboveThreshold"]?.asInt ?? 100
    }

    /// When true (default), desktop Macs render a plug icon + "AC Power"
    /// label instead of hiding the overlay. Renamed from `hideOnDesktop`
    /// so old configs that serialised `hideOnDesktop: true` are silently
    /// ignored and the new default (show) applies.
    private var showOnDesktop: Bool {
        instance.typeSettings["showOnDesktop"]?.asBool ?? true
    }

    var body: some View {
        let hasBattery = Battery.hasBattery()
        let percent = Battery.getRemainingPercent()
        let charging = !Battery.isUnplugged()

        if !isPreview && !hasBattery && !showOnDesktop {
            EmptyView()
        } else if !isPreview && hasBattery && hideAboveEnabled && percent >= hideAboveThreshold && charging {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                if displayMode != "textOnly" {
                    Image(systemName: iconName(hasBattery: hasBattery, percent: percent, charging: charging))
                        .symbolRenderingMode(.hierarchical)
                        .font(overlayFont(for: instance))
                }
                if displayMode != "iconOnly" {
                    Text(labelText(hasBattery: hasBattery, percent: percent))
                        .font(overlayFont(for: instance))
                }
            }
        }
    }

    private func iconName(hasBattery: Bool, percent: Int, charging: Bool) -> String {
        guard hasBattery else { return "powerplug" }

        let base: String
        switch percent {
        case 0..<13: base = "battery.0percent"
        case 13..<38: base = "battery.25percent"
        case 38..<63: base = "battery.50percent"
        case 63..<88: base = "battery.75percent"
        default: base = "battery.100percent"
        }

        return charging ? "battery.100percent.bolt" : base
    }

    private func labelText(hasBattery: Bool, percent: Int) -> String {
        guard hasBattery else { return "AC Power" }
        return "\(percent)%"
    }
}

private struct BatterySettingsContent: View {
    @Binding var instance: OverlayInstance

    private var displayMode: String {
        instance.typeSettings["displayMode"]?.asString ?? "iconAndText"
    }

    private var hideAboveEnabled: Bool {
        instance.typeSettings["hideAboveEnabled"]?.asBool ?? false
    }

    private var hideAboveThreshold: Int {
        instance.typeSettings["hideAboveThreshold"]?.asInt ?? 100
    }

    private var showOnDesktop: Bool {
        instance.typeSettings["showOnDesktop"]?.asBool ?? true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Display", selection: Binding(
                get: { displayMode },
                set: { instance.typeSettings["displayMode"] = .string($0) }
            )) {
                Text("Icon & Text").tag("iconAndText")
                Text("Text Only").tag("textOnly")
                Text("Icon Only").tag("iconOnly")
            }

            Toggle("Hide when charging above threshold", isOn: Binding(
                get: { hideAboveEnabled },
                set: { instance.typeSettings["hideAboveEnabled"] = .bool($0) }
            ))

            if hideAboveEnabled {
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(hideAboveThreshold) },
                            set: { instance.typeSettings["hideAboveThreshold"] = .int(Int($0)) }
                        ),
                        in: 20...100,
                        step: 5
                    )
                    Text("\(hideAboveThreshold)%")
                        .font(.callout.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                }
                .padding(.leading, 20)
            }

            Toggle("Show on desktop Macs", isOn: Binding(
                get: { showOnDesktop },
                set: { instance.typeSettings["showOnDesktop"] = .bool($0) }
            ))
        }
    }
}
