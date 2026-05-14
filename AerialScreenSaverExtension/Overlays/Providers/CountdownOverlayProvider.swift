//
//  CountdownOverlayProvider.swift
//  AerialScreenSaverExtension
//
//  Provider for countdown overlay type. Counts down to a specific date/time.
//

import SwiftUI

struct CountdownOverlayProvider: OverlayTypeProvider {
    static let kind: OverlayKind = .countdown

    static func makeView(instance: OverlayInstance, state: OverlayState) -> AnyView {
        AnyView(CountdownOverlayContent(instance: instance, state: state))
    }

    static func makeSettingsView(instance: Binding<OverlayInstance>) -> AnyView {
        AnyView(CountdownSettingsContent(instance: instance))
    }
}

// MARK: - Content View

private struct CountdownOverlayContent: View {
    let instance: OverlayInstance
    @ObservedObject var state: OverlayState

    var body: some View {
        if let text = countdownText() {
            Text(text)
                .font(overlayFont(for: instance))
        }
    }

    private func countdownText() -> String? {
        let mode = instance.typeSettings["mode"]?.asString ?? "preciseDate"
        let showSeconds = instance.typeSettings["showSeconds"]?.asBool ?? true
        let enforceInterval = instance.typeSettings["enforceInterval"]?.asBool ?? false

        let now = Date()

        // Parse target date
        var target: Date
        if let dateString = instance.typeSettings["targetDate"]?.asString, !dateString.isEmpty,
           let parsed = parseISO8601(dateString) {
            target = parsed
        } else {
            return ""
        }

        // In timeOfDay mode, transplant the time onto today
        if mode == "timeOfDay" {
            target = todayizeDate(target, strict: false)
        }

        // Check trigger interval
        if enforceInterval {
            if let triggerString = instance.typeSettings["triggerDate"]?.asString, !triggerString.isEmpty,
               let trigger = parseISO8601(triggerString) {
                let resolvedTrigger = mode == "timeOfDay" ? todayizeDate(trigger, strict: true) : trigger
                if now < resolvedTrigger {
                    return nil  // Hide until trigger time
                }
            }
        }

        // If countdown is done
        if now >= target {
            return ""
        }

        return formatCountdown(from: now, to: target, showSeconds: showSeconds)
    }

    private func formatCountdown(from: Date, to: Date, showSeconds: Bool) -> String {
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
            formatter.allowedUnits = [.day, .hour, .minute, .second]
            formatter.maximumUnitCount = 4
        } else {
            formatter.allowedUnits = [.day, .hour, .minute]
            formatter.maximumUnitCount = 3
        }

        return formatter.string(from: from, to: to) ?? ""
    }
}

// MARK: - Settings View

private struct CountdownSettingsContent: View {
    @Binding var instance: OverlayInstance

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private var mode: String {
        instance.typeSettings["mode"]?.asString ?? "preciseDate"
    }

    private var targetDate: Date {
        if let s = instance.typeSettings["targetDate"]?.asString, !s.isEmpty,
           let d = parseISO8601(s) {
            return d
        }
        return Date()
    }

    private var showSeconds: Bool {
        instance.typeSettings["showSeconds"]?.asBool ?? true
    }

    private var enforceInterval: Bool {
        instance.typeSettings["enforceInterval"]?.asBool ?? false
    }

    private var triggerDate: Date {
        if let s = instance.typeSettings["triggerDate"]?.asString, !s.isEmpty,
           let d = parseISO8601(s) {
            return d
        }
        return Date()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: Binding(
                get: { mode },
                set: { instance.typeSettings["mode"] = .string($0) }
            )) {
                Text("Precise Date").tag("preciseDate")
                Text("Time of Day").tag("timeOfDay")
            }

            if mode == "timeOfDay" {
                DatePicker("Target time", selection: Binding(
                    get: { targetDate },
                    set: { instance.typeSettings["targetDate"] = .string(Self.isoFormatter.string(from: $0)) }
                ), displayedComponents: .hourAndMinute)
            } else {
                DatePicker("Target date", selection: Binding(
                    get: { targetDate },
                    set: { instance.typeSettings["targetDate"] = .string(Self.isoFormatter.string(from: $0)) }
                ), displayedComponents: [.date, .hourAndMinute])
            }

            Toggle("Show seconds", isOn: Binding(
                get: { showSeconds },
                set: { instance.typeSettings["showSeconds"] = .bool($0) }
            ))

            Toggle("Only show after trigger time", isOn: Binding(
                get: { enforceInterval },
                set: { instance.typeSettings["enforceInterval"] = .bool($0) }
            ))

            if enforceInterval {
                if mode == "timeOfDay" {
                    DatePicker("Trigger time", selection: Binding(
                        get: { triggerDate },
                        set: { instance.typeSettings["triggerDate"] = .string(Self.isoFormatter.string(from: $0)) }
                    ), displayedComponents: .hourAndMinute)
                } else {
                    DatePicker("Trigger date", selection: Binding(
                        get: { triggerDate },
                        set: { instance.typeSettings["triggerDate"] = .string(Self.isoFormatter.string(from: $0)) }
                    ), displayedComponents: [.date, .hourAndMinute])
                }
            }
        }
    }
}

// MARK: - Helpers

private func parseISO8601(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
}

/// Transplant the time components of `target` onto today's date.
/// In non-strict mode, if the resulting time is in the past, wraps to tomorrow.
private func todayizeDate(_ target: Date, strict: Bool) -> Date {
    let now = Date()
    let calendar = Calendar.current

    var targetComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: target)
    let nowComponents = calendar.dateComponents([.year, .month, .day], from: now)

    targetComponents.year = nowComponents.year
    targetComponents.month = nowComponents.month
    targetComponents.day = nowComponents.day

    let candidate = calendar.date(from: targetComponents) ?? target

    if strict {
        return candidate
    } else {
        if candidate > now {
            return candidate
        } else {
            return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
    }
}
