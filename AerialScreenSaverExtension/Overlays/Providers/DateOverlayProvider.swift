//
//  DateOverlayProvider.swift
//  AerialScreenSaverExtension
//
//  Provider for date overlay type.
//

import SwiftUI

struct DateOverlayProvider: OverlayTypeProvider {
    static let kind: OverlayKind = .date

    static func makeView(instance: OverlayInstance, state: OverlayState) -> AnyView {
        AnyView(DateOverlayContent(instance: instance, state: state))
    }

    static func makeSettingsView(instance: Binding<OverlayInstance>) -> AnyView {
        AnyView(DateSettingsContent(instance: instance))
    }
}

private struct DateOverlayContent: View {
    let instance: OverlayInstance
    @ObservedObject var state: OverlayState

    var body: some View {
        Text(formatDate())
            .font(overlayFont(for: instance))
    }

    private func formatDate() -> String {
        let format = instance.typeSettings["format"]?.asString ?? "textual"
        let withYear = instance.typeSettings["withYear"]?.asBool ?? false
        var locale = Locale(identifier: Locale.preferredLanguages[0])
        if !PrefsAdvanced.ciOverrideLanguage.isEmpty {
            locale = Locale(identifier: PrefsAdvanced.ciOverrideLanguage)
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale

        switch format {
        case "compact":
            if withYear {
                dateFormatter.dateStyle = .short
            } else {
                dateFormatter.dateFormat = DateFormatter.dateFormat(
                    fromTemplate: "M/d", options: 0, locale: locale
                )
            }
        case "textual":
            let template = withYear ? "EEEE, MMMM d, yyyy" : "EEEE, MMMM d"
            dateFormatter.dateFormat = DateFormatter.dateFormat(
                fromTemplate: template, options: 0, locale: locale
            )
        default:
            dateFormatter.dateFormat = DateFormatter.dateFormat(
                fromTemplate: "EEEE, MMMM d", options: 0, locale: locale
            )
        }

        return dateFormatter.string(from: Date())
    }
}

private struct DateSettingsContent: View {
    @Binding var instance: OverlayInstance

    private var format: String {
        instance.typeSettings["format"]?.asString ?? "textual"
    }

    private var withYear: Bool {
        instance.typeSettings["withYear"]?.asBool ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Format", selection: Binding(
                get: { format },
                set: { instance.typeSettings["format"] = .string($0) }
            )) {
                Text("Textual").tag("textual")
                Text("Compact").tag("compact")
            }

            Toggle("Show year", isOn: Binding(
                get: { withYear },
                set: { instance.typeSettings["withYear"] = .bool($0) }
            ))
        }
    }
}
