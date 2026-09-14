//
//  ClockOverlayProvider.swift
//  AerialScreenSaverExtension
//
//  Provider for clock overlay type.
//

import SwiftUI

struct ClockOverlayProvider: OverlayTypeProvider {
    static let kind: OverlayKind = .clock

    static func makeView(instance: OverlayInstance, state: OverlayState) -> AnyView {
        AnyView(ClockOverlayContent(instance: instance, state: state))
    }

    static func makeSettingsView(instance: Binding<OverlayInstance>) -> AnyView {
        AnyView(ClockSettingsContent(instance: instance))
    }
}

private struct ClockOverlayContent: View {
    let instance: OverlayInstance
    @ObservedObject var state: OverlayState

    var body: some View {
        Text(attributedClock(formatClock()))
            .font(overlayFont(for: instance))
    }

    /// Build the clock text as an `AttributedString`, optionally making
    /// the colon separators invisible on odd seconds so the clock
    /// visibly "ticks". Setting `foregroundColor` to `.clear` keeps the
    /// colon glyphs in the layout — only their colour changes — so
    /// digits never shift horizontally the way a `":" ↔ " "` string
    /// swap would.
    private func attributedClock(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let flash = instance.typeSettings["flashSeparator"]?.asBool ?? false
        guard flash else { return attributed }

        // Even wall-clock second → colons visible, odd → hidden.
        // `OverlayState.clockTimer` fires `objectWillChange` every
        // second, so this view re-evaluates and the state alternates.
        let visible = Int(Date().timeIntervalSinceReferenceDate) % 2 == 0
        if visible { return attributed }

        var searchRange = attributed.startIndex..<attributed.endIndex
        while let colonRange = attributed[searchRange].range(of: ":") {
            attributed[colonRange].foregroundColor = .clear
            searchRange = colonRange.upperBound..<attributed.endIndex
        }
        return attributed
    }

    private func formatClock() -> String {
        let showSeconds = instance.typeSettings["showSeconds"]?.asBool ?? true
        let format = instance.typeSettings["clockFormat"]?.asString ?? "default"

        let dateFormatter = DateFormatter()
        var locale = Locale(identifier: Locale.preferredLanguages[0])
        if !PrefsAdvanced.ciOverrideLanguage.isEmpty {
            locale = Locale(identifier: PrefsAdvanced.ciOverrideLanguage)
        }

        switch format {
        case "24hours":
            dateFormatter.locale = Locale(identifier: "fr_FR")
            dateFormatter.dateFormat = DateFormatter.dateFormat(
                fromTemplate: showSeconds ? "HH:mm:ss" : "HH:mm",
                options: 0,
                locale: Locale(identifier: "fr_FR")
            )
        case "12hours":
            dateFormatter.locale = Locale(identifier: "en_US")
            dateFormatter.dateFormat = DateFormatter.dateFormat(
                fromTemplate: showSeconds ? "h:mm:ss a" : "h:mm a",
                options: 0,
                locale: Locale(identifier: "en_US")
            )
        default:
            dateFormatter.dateFormat = DateFormatter.dateFormat(
                fromTemplate: showSeconds ? "j:mm:ss" : "j:mm",
                options: 0,
                locale: locale
            )
        }

        let hideAmPm = instance.typeSettings["hideAmPm"]?.asBool ?? false
        if hideAmPm {
            dateFormatter.amSymbol = ""
            dateFormatter.pmSymbol = ""
        }

        return dateFormatter.string(from: Date())
    }
}

private struct ClockSettingsContent: View {
    @Binding var instance: OverlayInstance

    private var showSeconds: Bool {
        instance.typeSettings["showSeconds"]?.asBool ?? true
    }

    private var hideAmPm: Bool {
        instance.typeSettings["hideAmPm"]?.asBool ?? false
    }

    private var clockFormat: String {
        instance.typeSettings["clockFormat"]?.asString ?? "default"
    }

    private var flashSeparator: Bool {
        instance.typeSettings["flashSeparator"]?.asBool ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show seconds", isOn: Binding(
                get: { showSeconds },
                set: { instance.typeSettings["showSeconds"] = .bool($0) }
            ))

            Toggle("Hide AM/PM", isOn: Binding(
                get: { hideAmPm },
                set: { instance.typeSettings["hideAmPm"] = .bool($0) }
            ))

            Toggle("Flash time separator", isOn: Binding(
                get: { flashSeparator },
                set: { instance.typeSettings["flashSeparator"] = .bool($0) }
            ))

            Picker("Format", selection: Binding(
                get: { clockFormat },
                set: { instance.typeSettings["clockFormat"] = .string($0) }
            )) {
                Text("System Default").tag("default")
                Text("24 Hours").tag("24hours")
                Text("12 Hours").tag("12hours")
            }
        }
    }
}
