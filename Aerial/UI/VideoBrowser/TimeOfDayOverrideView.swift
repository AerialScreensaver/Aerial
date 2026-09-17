//
//  TimeOfDayOverrideView.swift
//  Aerial Companion
//
//  Reusable picker for overriding a video's time-of-day classification.
//

import AVFoundation
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

// MARK: - Rotation override (local files)

/// The per-video extra rotation: degrees clockwise on top of the clip's
/// own orientation metadata, for local files whose metadata is missing
/// or wrong (an iPhone clip that plays upside down). Stored with the
/// other per-video overrides in screensaver.json; the wallpaper
/// extension re-reads it on the settings-generation bump and applies it
/// the next time the clip starts.
enum RotationOverride {
    static let options: [(degrees: Int, label: String)] = [
        (0, "None"), (90, "90°"), (180, "180°"), (270, "270°"),
    ]

    static func degrees(for video: AerialVideo) -> Int {
        PrefsVideos.rotationOverride[video.id] ?? 0
    }

    /// Persist `degrees` for `videos` (0 removes the entry), refresh their
    /// portrait verdict in place, and tell the extension.
    static func apply(_ degrees: Int, to videos: [AerialVideo]) {
        var overrides = PrefsVideos.rotationOverride
        for video in videos {
            if degrees == 0 {
                overrides.removeValue(forKey: video.id)
            } else {
                overrides[video.id] = degrees
            }
            if video.url.isFileURL, FileManager.default.fileExists(atPath: video.url.path) {
                video.isVertical = AVURLAsset(url: video.url).isVertical(extraRotation: degrees)
            }
        }
        PrefsVideos.rotationOverride = overrides
        debugLog("🔄 rotation override \(degrees)° for \(videos.map(\.secondaryName))")
        WallpaperControl.shared.displaysConfigDidChange()
    }
}

/// Inspector section: segmented picker for the extra rotation.
struct RotationOverrideView: View {
    let video: AerialVideo
    @ObservedObject var state: VideoBrowserState

    private var selection: Binding<Int> {
        Binding(
            get: { RotationOverride.degrees(for: video) },
            set: { degrees in
                RotationOverride.apply(degrees, to: [video])
                state.refreshTrigger += 1
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rotation")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Picker("Rotation", selection: selection) {
                ForEach(RotationOverride.options, id: \.degrees) { option in
                    Text(option.label).tag(option.degrees)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Extra rotation on top of the clip's own orientation metadata. Takes effect the next time the video plays.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Thumbnail preview of the override: rotates the (metadata-upright)
/// thumbnail by the extra degrees, scaling quarter turns so the frame
/// stays covered.
struct RotationOverridePreview: ViewModifier {
    let degrees: Int

    func body(content: Content) -> some View {
        if degrees == 0 {
            content
        } else {
            GeometryReader { geo in
                let longest = max(geo.size.width, geo.size.height)
                let shortest = max(1, min(geo.size.width, geo.size.height))
                let scale = degrees % 180 == 0 ? 1 : longest / shortest
                content
                    .frame(width: geo.size.width, height: geo.size.height)
                    .rotationEffect(.degrees(Double(degrees)))
                    .scaleEffect(scale)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        }
    }
}

extension View {
    func rotatedByOverride(_ degrees: Int) -> some View {
        modifier(RotationOverridePreview(degrees: degrees))
    }
}
