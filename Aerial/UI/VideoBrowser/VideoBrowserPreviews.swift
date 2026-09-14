//
//  VideoBrowserPreviews.swift
//  Aerial Companion
//
//  Shared mock data factories for SwiftUI previews.
//

import SwiftUI

enum PreviewData {
    static func makeVideo(
        id: String = "PREVIEW-001",
        name: String = "Hawaii",
        secondaryName: String = "Laupāhoehoe Nui",
        timeOfDay: String = "day",
        scene: String = "beach"
    ) -> AerialVideo {
        AerialVideo(
            id: id,
            name: name,
            secondaryName: secondaryName,
            type: "video",
            timeOfDay: timeOfDay,
            scene: scene,
            urls: [.v1080pH264: "https://example.com/v.mp4"],
            sources: [Source(
                name: "Preview",
                description: "Preview source",
                manifestUrl: "",
                type: .tvOS12,
                scenes: [.beach, .nature],
                isCachable: false,
                license: "",
                more: ""
            )],
            poi: [:]
        )
    }

    static func makeState(
        sidebar: BrowseCategory = .allVideos,
        selectedVideo: AerialVideo? = nil
    ) -> VideoBrowserState {
        let s = VideoBrowserState()
        s.selectedSidebarItem = sidebar
        if let video = selectedVideo {
            s.selectedVideoIds = [video.id]
        }
        return s
    }

    static let sampleVideos: [AerialVideo] = [
        makeVideo(id: "P-001", name: "Hawaii", secondaryName: "Laupāhoehoe Nui", timeOfDay: "day", scene: "beach"),
        makeVideo(id: "P-002", name: "London", secondaryName: "River Thames", timeOfDay: "night", scene: "city"),
        makeVideo(id: "P-003", name: "Greenland", secondaryName: "Ilulissat Icefjord", timeOfDay: "sunset", scene: "nature"),
        makeVideo(id: "P-004", name: "Hong Kong", secondaryName: "Victoria Harbour", timeOfDay: "sunrise", scene: "city"),
    ]
}
