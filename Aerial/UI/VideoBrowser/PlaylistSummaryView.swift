//
//  PlaylistSummaryView.swift
//  Aerial Companion
//
//  Content view for the "Now Playing" sidebar item.
//  Groups playlist videos by time-of-day slice so playback behavior is clear.
//

import SwiftUI
import Combine

struct PlaylistSummaryView: View {
    @ObservedObject var state: VideoBrowserState

    @State private var timerTick = Date()

    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private static let sunTimeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = DateFormatter.dateFormat(fromTemplate: "j:mm", options: 0, locale: .current)
        return fmt
    }()

    private var screenUUID: String? {
        if case .nowPlaying(let uuid) = state.selectedSidebarItem {
            return uuid
        }
        return nil
    }

    private var entries: [PlaylistEntry] {
        PlaylistManager.shared.allEntries(for: screenUUID)
    }

    private var currentVideoId: String? {
        let idx = PlaylistManager.shared.currentIndex(for: screenUUID)
        let all = entries
        guard idx >= 0, idx < all.count else { return nil }
        return all[idx].videoId
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(timer) { timerTick = $0 }
    }

    // MARK: - Content Routing

    @ViewBuilder
    private var content: some View {
        if PrefsTime.darkModeNightOverride && DarkMode.isEnabled() {
            darkModeOverrideContent
        } else {
            switch PrefsTime.timeMode {
            case .disabled:
                flatGrid
            case .lightDarkMode:
                lightDarkContent
            case .nightShift, .manual, .coordinates, .locationService:
                solarContent
            }
        }
    }

    // MARK: - Flat Grid (time mode disabled)

    private var flatGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 200, maximum: 200), spacing: 12)]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(entries, id: \.videoId) { entry in
                if let video = resolveVideo(entry) {
                    VideoBrowserCardView(
                        video: video,
                        state: state,
                        isCurrent: entry.videoId == currentVideoId
                    )
                }
            }
        }
    }

    // MARK: - Dark Mode Override

    @ViewBuilder
    private var darkModeOverrideContent: some View {
        // Header
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "moon.fill")
                    .font(.system(size: 18))
                Text("Dark Mode Override")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            Text("Night videos only while Dark Mode is active")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))

        // Single Night section
        sliceSection(
            slice: "night",
            headerText: "Now",
            videos: videosForSlice("night")
        )
    }

    // MARK: - Light/Dark Mode (2 sections)

    @ViewBuilder
    private var lightDarkContent: some View {
        // Header
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: DarkMode.isEnabled() ? "moon.fill" : "sun.max.fill")
                    .font(.system(size: 18))
                Text("Light/Dark Mode")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: DarkMode.isEnabled() ? "moon.fill" : "sun.max.fill")
                    .font(.system(size: 14))
                Text("Currently: \(DarkMode.isEnabled() ? "Night" : "Day") videos")
                    .font(.system(size: 13))
            }
            .foregroundColor(.aerial)
            Text("Follows system appearance")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))

        // Day section (sunrise videos included in day)
        let dayVideos = videosForSlice("day") + videosForSlice("sunrise")
        let nightVideos = videosForSlice("night") + videosForSlice("sunset")

        let isDark = DarkMode.isEnabled()

        sliceSection(
            slice: isDark ? "night" : "day",
            headerText: "Now",
            videos: isDark ? nightVideos : dayVideos
        )
        sliceSection(
            slice: isDark ? "day" : "night",
            headerText: "When appearance changes",
            videos: isDark ? dayVideos : nightVideos
        )
    }

    // MARK: - Solar Content (4 sections)

    @ViewBuilder
    private var solarContent: some View {
        let (_, currentSlice) = TimeManagement.sharedInstance.shouldRestrictPlaybackToDayNightVideo()
        let transitionDate = TimeManagement.sharedInstance.nextTransitionDate()
        let sunTimes = TimeManagement.sharedInstance.todayizedSunriseSunset()

        // Header card
        solarHeaderCard(currentSlice: currentSlice, transitionDate: transitionDate, sunTimes: sunTimes)

        // 4 sections ordered current-first
        let slices = orderedSlices(from: currentSlice)
        let boundaries = sliceBoundaries(sunTimes: sunTimes)

        ForEach(slices, id: \.self) { slice in
            let isCurrent = slice == currentSlice
            let headerText: String = {
                if isCurrent {
                    if let td = transitionDate {
                        return "Now — \(timeRemainingString(until: td)) remaining"
                    }
                    return "Now"
                }
                if let start = boundaries[slice] {
                    let fmt = DateFormatter()
                    fmt.dateFormat = DateFormatter.dateFormat(fromTemplate: "j:mm", options: 0, locale: .current)
                    return "Starts at \(fmt.string(from: start))"
                }
                return ""
            }()

            sliceSection(
                slice: slice,
                headerText: headerText,
                videos: videosForSlice(slice)
            )
        }
    }

    // MARK: - Solar Header Card

    private func solarHeaderCard(currentSlice: String, transitionDate: Date?, sunTimes: (sunrise: Date, sunset: Date)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: timeOfDayIcon(currentSlice))
                    .font(.system(size: 18))
                Text(state.timeModeName())
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            HStack(spacing: 6) {
                Image(systemName: timeOfDayIcon(currentSlice))
                    .font(.system(size: 14))
                if let td = transitionDate {
                    let next = nextTimeSlice(currentSlice)
                    Text("Changes to \(next) in \(timeRemainingString(until: td))")
                        .font(.system(size: 13))
                } else {
                    Text("Currently: \(currentSlice.capitalized)")
                        .font(.system(size: 13))
                }
            }
            .foregroundColor(.aerial)

            if let st = sunTimes {
                let fmt = Self.sunTimeFormatter
                HStack(spacing: 12) {
                    Label(fmt.string(from: st.sunrise), systemImage: "sunrise")
                    Label(fmt.string(from: st.sunset), systemImage: "sunset")
                }
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }

    // MARK: - Time Slice Section

    private func sliceSection(slice: String, headerText: String, videos: [AerialVideo]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 200, maximum: 200), spacing: 12)]

        return VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: timeOfDayIcon(slice))
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                Text(slice.capitalized)
                    .font(.system(size: 14, weight: .semibold))
                if !headerText.isEmpty {
                    Text("  \(headerText)")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if videos.isEmpty {
                // Empty section placeholder
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: timeOfDayIcon(slice))
                            .font(.system(size: 24))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("No \(slice) videos in playlist")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        let fallbackSlice = nextTimeSlice(slice)
                        let hasFallback = !videosForSlice(fallbackSlice).isEmpty
                        Text(hasFallback
                             ? "\(fallbackSlice.capitalized) videos will play as fallback"
                             : "All playlist videos will play as fallback")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .padding(.vertical, 24)
                    Spacer()
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .foregroundColor(.secondary.opacity(0.3))
                )
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(videos, id: \.id) { video in
                        VideoBrowserCardView(
                            video: video,
                            state: state,
                            isCurrent: video.id == currentVideoId
                        )
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func resolveVideo(_ entry: PlaylistEntry) -> AerialVideo? {
        VideoList.instance.videos.first(where: { $0.id == entry.videoId })
    }

    private func videosForSlice(_ slice: String) -> [AerialVideo] {
        let videoIds = Set(entries.map(\.videoId))
        return VideoList.instance.videos.filter { video in
            videoIds.contains(video.id) && video.timeOfDay == slice
        }
    }

    private func orderedSlices(from current: String) -> [String] {
        var result = [current]
        var next = nextTimeSlice(current)
        while next != current {
            result.append(next)
            next = nextTimeSlice(next)
        }
        return result
    }

    /// Compute the start date of each slice from todayized sunrise/sunset + window.
    private func sliceBoundaries(sunTimes: (sunrise: Date, sunset: Date)?) -> [String: Date] {
        guard let st = sunTimes else { return [:] }
        let window = TimeInterval(PrefsTime.sunEventWindow)
        // sunrise slice starts at sunrise
        // day starts at sunrise + window
        // sunset starts at sunset - window
        // night starts at sunset
        return [
            "sunrise": st.sunrise,
            "day": st.sunrise.addingTimeInterval(window),
            "sunset": st.sunset.addingTimeInterval(-window),
            "night": st.sunset
        ]
    }
}

struct PlaylistSummaryView_Previews: PreviewProvider {
    static var previews: some View {
        PlaylistSummaryView(state: PreviewData.makeState(sidebar: .nowPlaying(screenUUID: nil)))
            .frame(width: 600, height: 500)
    }
}
