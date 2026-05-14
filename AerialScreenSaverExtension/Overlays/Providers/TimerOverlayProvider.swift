//
//  TimerOverlayProvider.swift
//  AerialScreenSaverExtension
//
//  Provider for timer overlay type. Counts down from a set duration.
//

import SwiftUI

struct TimerOverlayProvider: OverlayTypeProvider {
    static let kind: OverlayKind = .timer

    static func makeView(instance: OverlayInstance, state: OverlayState) -> AnyView {
        AnyView(TimerOverlayContent(instance: instance, state: state))
    }

    static func makeSettingsView(instance: Binding<OverlayInstance>) -> AnyView {
        AnyView(TimerSettingsContent(instance: instance))
    }
}

private struct TimerOverlayContent: View {
    let instance: OverlayInstance
    @ObservedObject var state: OverlayState

    var body: some View {
        Text(formatTimer())
            .font(overlayFont(for: instance))
    }

    private func formatTimer() -> String {
        let duration = instance.typeSettings["duration"]?.asInt ?? 300
        let showSeconds = instance.typeSettings["showSeconds"]?.asBool ?? true
        let replaceWithMessage = instance.typeSettings["replaceWithMessage"]?.asBool ?? false
        let customMessage = instance.typeSettings["customMessage"]?.asString ?? ""

        let endTime = state.activationTime.addingTimeInterval(TimeInterval(duration))
        let now = Date()

        if now >= endTime {
            if replaceWithMessage && !customMessage.isEmpty {
                return customMessage
            }
            return formatComponents(from: 0, showSeconds: showSeconds)
        }

        let remaining = endTime.timeIntervalSince(now)
        return formatComponents(from: remaining, showSeconds: showSeconds)
    }

    private func formatComponents(from interval: TimeInterval, showSeconds: Bool) -> String {
        var locale = Locale(identifier: Locale.preferredLanguages[0])
        if !PrefsAdvanced.ciOverrideLanguage.isEmpty {
            locale = Locale(identifier: PrefsAdvanced.ciOverrideLanguage)
        }

        var calendar = Calendar.current
        calendar.locale = locale

        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = .full

        if showSeconds {
            formatter.allowedUnits = [.hour, .minute, .second]
            formatter.maximumUnitCount = 3
        } else {
            formatter.allowedUnits = [.hour, .minute]
            formatter.maximumUnitCount = 2
        }

        return formatter.string(from: max(interval, 0)) ?? "0 seconds"
    }
}

private struct TimerSettingsContent: View {
    @Binding var instance: OverlayInstance

    private var durationSeconds: Int {
        instance.typeSettings["duration"]?.asInt ?? 300
    }

    private var hours: Int { durationSeconds / 3600 }
    private var minutes: Int { (durationSeconds % 3600) / 60 }

    private var showSeconds: Bool {
        instance.typeSettings["showSeconds"]?.asBool ?? true
    }

    private var replaceWithMessage: Bool {
        instance.typeSettings["replaceWithMessage"]?.asBool ?? false
    }

    private var customMessage: String {
        instance.typeSettings["customMessage"]?.asString ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Duration:")
                Picker("Hours", selection: Binding(
                    get: { hours },
                    set: { newHours in
                        instance.typeSettings["duration"] = .int(newHours * 3600 + minutes * 60)
                    }
                )) {
                    ForEach(0..<24, id: \.self) { h in
                        Text("\(h)h").tag(h)
                    }
                }
                .frame(width: 70)

                Picker("Minutes", selection: Binding(
                    get: { minutes },
                    set: { newMinutes in
                        instance.typeSettings["duration"] = .int(hours * 3600 + newMinutes * 60)
                    }
                )) {
                    ForEach(0..<60, id: \.self) { m in
                        Text("\(m)m").tag(m)
                    }
                }
                .frame(width: 70)
            }

            Toggle("Show seconds", isOn: Binding(
                get: { showSeconds },
                set: { instance.typeSettings["showSeconds"] = .bool($0) }
            ))

            Toggle("Replace with message when elapsed", isOn: Binding(
                get: { replaceWithMessage },
                set: { instance.typeSettings["replaceWithMessage"] = .bool($0) }
            ))

            if replaceWithMessage {
                TextField("Custom message", text: Binding(
                    get: { customMessage },
                    set: { instance.typeSettings["customMessage"] = .string($0) }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }
}
