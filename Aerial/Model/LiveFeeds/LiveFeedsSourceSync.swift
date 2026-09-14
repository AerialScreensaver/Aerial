//
//  LiveFeedsSourceSync.swift
//  Aerial
//
//  Bridges `LiveFeedManager` (Companion-only store) to the shared
//  "Live Feeds" source folder the extension reads from. For each live
//  feed we emit one `VideoAsset` in `entries.json` whose URL is the
//  *playback* URL (resolved HLS for YouTube, verbatim for HLS). If a
//  feed has no resolved URL yet it is omitted from the manifest.
//
//  Companion-only. The extension does not need this class.
//

import Foundation

final class LiveFeedsSourceSync {
    static let shared = LiveFeedsSourceSync()

    static let sourceName = "Live Feeds"

    private init() {}

    /// Write (or rewrite) the shared "Live Feeds" source folder so the
    /// extension's `SourceList` scan picks up the current set of feeds.
    func sync(feeds: [LiveFeed]) {
        let source = Source(
            name: Self.sourceName,
            description: "User-configured live streams",
            manifestUrl: "",
            type: .live,
            scenes: [.nature],
            isCachable: false,
            license: "",
            more: ""
        )

        // manifest.json — metadata Source/SourceList use to reload the source.
        SourceList.saveSource(source)

        // entries.json — one VideoAsset per resolved feed.
        let assets: [VideoAsset] = feeds.compactMap { feed in
            guard let playbackURL = feed.playbackURL, !playbackURL.isEmpty else { return nil }
            return VideoAsset(
                accessibilityLabel: feed.displayName,
                id: feed.id.uuidString,
                title: feed.displayName,
                timeOfDay: "day",
                scene: "nature",
                pointsOfInterest: [:],
                url4KHDR: playbackURL,
                url4KSDR: playbackURL,
                url1080H264: playbackURL,
                url1080HDR: playbackURL,
                url4KSDR120FPS: playbackURL,
                url4KSDR240FPS: playbackURL,
                url1080SDR: playbackURL,
                url: playbackURL,
                type: "video",
                isLive: true,
                livePlaybackSeconds: feed.playbackSeconds
            )
        }

        let manifest = VideoManifest(assets: assets, initialAssetCount: assets.count, version: 1)
        SourceList.saveEntries(source: source, manifest: manifest)

        // Make sure the source is in the in-memory list and enabled, then
        // reload so the Video Library / picker pick up changes.
        if !SourceList.list.contains(where: { $0.name == Self.sourceName }) {
            SourceList.list.append(source)
        }
        source.setEnabled(true)
        VideoList.instance.reloadSources()
    }

    /// Called once at startup (from AppDelegate) to make sure the source
    /// folder reflects what's currently in `live-feeds.json`, even if the
    /// user never touches the Live Feeds settings panel this session.
    func syncFromManager() {
        sync(feeds: LiveFeedManager.shared.allFeeds())
    }
}
