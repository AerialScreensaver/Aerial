//
//  LiveFeed.swift
//  Aerial
//
//  User-facing configuration for a single live stream entry.
//  Stored in ~/Library/Application Support/Aerial/live-feeds.json
//  (Companion-only, never shared with the extension — see LiveFeedsSourceSync).
//

import Foundation

enum LiveFeedKind: String, Codable, CaseIterable, Identifiable {
    case hls        // Any direct HTTP/HTTPS HLS or progressive stream
    case youtube    // YouTube live — resolved via yt-dlp
    case rtsp       // RTSP — transmuxed via ffmpeg (Phase 4, not yet wired)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hls: return "HLS / HTTP"
        case .youtube: return "YouTube Live"
        case .rtsp: return "RTSP"
        }
    }

    /// Best-guess detection from a user-entered URL string.
    static func detect(from url: String) -> LiveFeedKind {
        let lower = url.lowercased()
        if lower.hasPrefix("rtsp://") || lower.hasPrefix("rtsps://") {
            return .rtsp
        }
        if lower.contains("youtube.com") || lower.contains("youtu.be") {
            return .youtube
        }
        return .hls
    }
}

struct LiveFeed: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var sourceURL: String
    var kind: LiveFeedKind
    /// How long to play this feed before rotating to the next video.
    var playbackSeconds: Double
    var addedAt: Date
    /// YouTube: resolved HLS URL from `yt-dlp -g`. Null until first resolve.
    var resolvedURL: String?
    /// When `resolvedURL` was last populated. Used to drive TTL refresh.
    var resolvedAt: Date?
    /// Optional path to a thumbnail frame in the source's thumbs folder.
    var thumbnailPath: String?

    init(id: UUID = UUID(),
         displayName: String,
         sourceURL: String,
         kind: LiveFeedKind? = nil,
         playbackSeconds: Double = 300,
         addedAt: Date = Date(),
         resolvedURL: String? = nil,
         resolvedAt: Date? = nil,
         thumbnailPath: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.sourceURL = sourceURL
        self.kind = kind ?? LiveFeedKind.detect(from: sourceURL)
        self.playbackSeconds = playbackSeconds
        self.addedAt = addedAt
        self.resolvedURL = resolvedURL
        self.resolvedAt = resolvedAt
        self.thumbnailPath = thumbnailPath
    }

    /// URL the extension should actually play. Resolved for YouTube, verbatim
    /// for direct HLS/HTTP. `nil` when resolution is still pending / failed.
    var playbackURL: String? {
        switch kind {
        case .hls: return sourceURL
        case .youtube: return resolvedURL
        case .rtsp: return resolvedURL  // will be populated by Phase 4 transmuxer
        }
    }
}

struct LiveFeedsIndex: Codable {
    var version: Int
    var feeds: [LiveFeed]

    static let currentVersion = 1
    static let empty = LiveFeedsIndex(version: currentVersion, feeds: [])
}
