//
//  TimeOfDayOverrideView.swift
//  Aerial Companion
//
//  Reusable picker for overriding a video's time-of-day classification.
//

import SwiftUI

struct TimeOfDayOverrideView: View {
    let video: AerialVideo
    @ObservedObject var state: VideoBrowserState

    private var originalValue: String {
        // SourceInfo hardcoded > raw manifest value (never the user override)
        if let hardcoded = SourceInfo.timeInformation[video.id] {
            return hardcoded
        }
        return video.manifestTimeOfDay
    }

    private var currentOverride: String? {
        PrefsVideos.timeOfDayOverride[video.id]
    }

    private var effectiveValue: String {
        currentOverride ?? originalValue
    }

    private let options: [(String, String, String)] = [
        ("day", "sun.max", "Day"),
        ("sunrise", "sunrise", "Sunrise"),
        ("sunset", "sunset", "Sunset"),
        ("night", "moon.stars", "Night"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Time of Day")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            // Original classification
            HStack(spacing: 4) {
                Text("Original:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Image(systemName: timeOfDayIcon(originalValue))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(originalValue.capitalized)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                if SourceInfo.timeInformation[video.id] != nil {
                    Text("(hardcoded)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }

            // Segmented picker
            HStack(spacing: 2) {
                ForEach(options, id: \.0) { value, icon, label in
                    let isActive = effectiveValue == value
                    Button(action: { applyOverride(value) }) {
                        VStack(spacing: 2) {
                            Image(systemName: icon)
                                .font(.system(size: 14))
                            Text(label)
                                .font(.system(size: 9))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(isActive ? Color.aerial.opacity(0.15) : Color.clear)
                        .foregroundColor(isActive ? .aerial : .secondary)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.borderless)
                    .help("Override to \(label)")
                    .accessibilityLabel("Set time of day to \(label)")
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
            )

            // Reset button
            if currentOverride != nil {
                Button(action: resetOverride) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10))
                        Text("Reset to Original")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
                .foregroundColor(.aerial)
            }
        }
    }

    // MARK: - Actions

    private func applyOverride(_ value: String) {
        if value == originalValue && currentOverride != nil {
            // Setting back to original, just remove the override
            resetOverride()
            return
        }
        if value == originalValue && currentOverride == nil {
            // Already at original, nothing to do
            return
        }
        var overrides = PrefsVideos.timeOfDayOverride
        overrides[video.id] = value
        PrefsVideos.timeOfDayOverride = overrides
        video.timeOfDay = value
        state.refreshTrigger += 1
    }

    private func resetOverride() {
        var overrides = PrefsVideos.timeOfDayOverride
        overrides.removeValue(forKey: video.id)
        PrefsVideos.timeOfDayOverride = overrides
        video.timeOfDay = originalValue
        state.refreshTrigger += 1
    }
}

struct TimeOfDayOverrideView_Previews: PreviewProvider {
    static var previews: some View {
        let video = PreviewData.makeVideo()
        TimeOfDayOverrideView(video: video, state: PreviewData.makeState())
            .padding(12)
            .frame(width: 260)
    }
}
