//
//  ScreensaverTimelineView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 19/03/2026.
//

import SwiftUI

struct ScreensaverTimelineView: View {
    let activationMinutes: Int
    let displaySleepMinutes: Int

    private let barHeight: CGFloat = 32

    // MARK: - Computed State

    private var scenario: Scenario {
        let act = activationMinutes
        let sleep = displaySleepMinutes

        if act == 0 {
            return .disabled
        } else if sleep == 0 {
            return .indefinite
        } else if act > sleep {
            return .sleepBeforeActivation
        } else if act == sleep {
            return .sleepEqualsActivation
        } else {
            return .normal
        }
    }

    private enum Scenario {
        case normal
        case sleepEqualsActivation
        case sleepBeforeActivation
        case indefinite
        case disabled
    }

    // MARK: - Bar Segments

    private var segments: [(label: String, fraction: CGFloat, color: Color)] {
        let act = CGFloat(activationMinutes)
        let sleep = CGFloat(displaySleepMinutes)

        switch scenario {
        case .normal:
            let total = sleep
            let idleFrac = act / total
            let saverFrac = (sleep - act) / total
            return [
                ("Idle", idleFrac, Color.gray),
                ("Screensaver", saverFrac, Color.teal),
                ("Display off", 0.02, Color(NSColor.darkGray)),
            ]

        case .sleepEqualsActivation, .sleepBeforeActivation:
            let total = max(act, sleep)
            let idleFrac = min(sleep, act) / total
            return [
                ("Idle", idleFrac, Color.gray),
                ("Display off", 0.02, Color(NSColor.darkGray)),
            ]

        case .indefinite:
            let total = max(act * 2, act + 30)
            let idleFrac = act / total
            let saverFrac = 1.0 - idleFrac
            return [
                ("Idle", idleFrac, Color.gray),
                ("Screensaver", saverFrac, Color.teal),
            ]

        case .disabled:
            return [
                ("Idle", 1.0, Color.gray),
            ]
        }
    }

    // MARK: - Time Labels

    private var timeLabels: [(time: String, fraction: CGFloat)] {
        let act = CGFloat(activationMinutes)
        let sleep = CGFloat(displaySleepMinutes)

        switch scenario {
        case .normal:
            let total = sleep
            return [
                ("0", 0),
                (formatMinutes(activationMinutes), act / total),
                (formatMinutes(displaySleepMinutes), 1.0),
            ]

        case .sleepEqualsActivation:
            return [
                ("0", 0),
                (formatMinutes(activationMinutes), 1.0),
            ]

        case .sleepBeforeActivation:
            return [
                ("0", 0),
                (formatMinutes(displaySleepMinutes), sleep / act),
                (formatMinutes(activationMinutes), 1.0),
            ]

        case .indefinite:
            let total = max(act * 2, act + 30)
            return [
                ("0", 0),
                (formatMinutes(activationMinutes), act / total),
            ]

        case .disabled:
            return [
                ("0", 0),
            ]
        }
    }

    // MARK: - Legend

    private var legendItems: [(color: Color, label: String)] {
        switch scenario {
        case .normal:
            return [
                (.gray, "Idle"),
                (.teal, "Screensaver"),
                (Color(NSColor.darkGray), "Display off"),
            ]
        case .sleepEqualsActivation, .sleepBeforeActivation:
            return [
                (.gray, "Idle"),
                (Color(NSColor.darkGray), "Display off"),
            ]
        case .indefinite:
            return [
                (.gray, "Idle"),
                (.teal, "Screensaver"),
            ]
        case .disabled:
            return [
                (.gray, "Idle"),
            ]
        }
    }

    // MARK: - Summary Text

    private var summaryText: String {
        switch scenario {
        case .normal:
            let runtime = displaySleepMinutes - activationMinutes
            return "Aerial will play for \(formatMinutes(runtime)) after your Mac has been idle for \(formatMinutes(activationMinutes))."
        case .sleepEqualsActivation:
            return "Your display will sleep as soon as the screensaver starts — it won't be visible."
        case .sleepBeforeActivation:
            return "Your display sleeps before the screensaver can start."
        case .indefinite:
            return "Aerial will play indefinitely after your Mac has been idle for \(formatMinutes(activationMinutes))."
        case .disabled:
            return "Screensaver is disabled."
        }
    }

    private var summaryColor: Color {
        switch scenario {
        case .normal, .indefinite:
            return .secondary
        case .sleepEqualsActivation, .sleepBeforeActivation:
            return .orange
        case .disabled:
            return .secondary
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Legend
            HStack(spacing: 16) {
                ForEach(Array(legendItems.enumerated()), id: \.offset) { _, item in
                    legendItem(color: item.color, label: item.label)
                }
            }
            .font(.system(size: 11))

            // Bar
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if segment.fraction > 0 {
                            RoundedRectangle(cornerRadius: 0)
                                .fill(segment.color)
                                .frame(width: max(segment.fraction * geo.size.width, 1))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(height: barHeight)

            // Time labels
            GeometryReader { geo in
                let totalWidth = geo.size.width
                ForEach(Array(timeLabels.enumerated()), id: \.offset) { idx, item in
                    Text(item.time)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .fixedSize()
                        .position(
                            x: clampLabelX(fraction: item.fraction, totalWidth: totalWidth, isLast: idx == timeLabels.count - 1),
                            y: 8
                        )
                }
            }
            .frame(height: 20)

            // Summary
            Text(summaryText)
                .font(.system(size: 12))
                .foregroundColor(summaryColor)
        }
    }

    // MARK: - Helpers

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 12, height: 12)
            Text(label)
                .foregroundColor(.secondary)
        }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 60 && minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        } else if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        } else {
            return "\(minutes) min"
        }
    }

    private func clampLabelX(fraction: CGFloat, totalWidth: CGFloat, isLast: Bool) -> CGFloat {
        let raw = fraction * totalWidth
        // Keep labels from going off-edge
        let minX: CGFloat = 16
        let maxX = totalWidth - 16
        if isLast && fraction >= 0.95 {
            return maxX
        }
        return max(minX, min(raw, maxX))
    }
}
