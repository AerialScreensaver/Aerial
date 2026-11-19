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
    /// Time slice (day / sunrise / sunset / night) the feed belongs to for
    /// day/night filtering, like a video's. Nil in feeds saved before the
    /// picker existed — they were catalogued as "day".
    var timeOfDay: String?
    /// Why the last resolve (yt-dlp, ffmpeg transmuxer) failed, and when.
    /// Nil after a successful resolve and in files written before these
    /// fields existed.
    var lastResolveError: String?
    var lastResolveFailedAt: Date?
    /// Consecutive failed resolves — drives the retry backoff. Nil (old
    /// files, or after a success) counts as none.
    var resolveFailureCount: Int?

    var effectiveTimeOfDay: String { timeOfDay ?? "day" }

    init(id: UUID = UUID(),
         displayName: String,
         sourceURL: String,
         kind: LiveFeedKind? = nil,
         playbackSeconds: Double = 300,
         addedAt: Date = Date(),
         resolvedURL: String? = nil,
         resolvedAt: Date? = nil,
         thumbnailPath: String? = nil,
         timeOfDay: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.sourceURL = sourceURL
        self.kind = kind ?? LiveFeedKind.detect(from: sourceURL)
        self.playbackSeconds = playbackSeconds
        self.addedAt = addedAt
        self.resolvedURL = resolvedURL
        self.resolvedAt = resolvedAt
        self.thumbnailPath = thumbnailPath
        self.timeOfDay = timeOfDay
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

/// When a resolved stream URL needs refreshing, how long it stays usable,
/// and how often a failing resolve may be retried. Pure — unit-tested in
/// LiveFeedResolvePolicyTests.
enum LiveFeedResolvePolicy {
    /// Re-resolve a YouTube URL once it is this old. The tokens last a
    /// few hours; refreshing early keeps a feed playable when its turn
    /// comes in a long playlist.
    static let refreshAfter: TimeInterval = 2 * 60 * 60
    /// Validity assumed for a URL that carries no readable expiry.
    static let assumedLifetime: TimeInterval = 4 * 60 * 60
    /// A URL this close to its expiry is treated as already expired.
    static let expiryMargin: TimeInterval = 60
    /// Gap before the next automatic resolve attempt, by number of
    /// consecutive failures: 5, 15, 30 minutes, then hourly. The failures
    /// seen in the field (YouTube's "confirm you're not a bot", a stream
    /// that no longer exists) do not clear in minutes, and hammering
    /// yt-dlp can prolong a bot check — a flat 5 minutes meant 12 runs an
    /// hour for every broken feed, forever.
    static let retryStepsAfterFailure: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 60 * 60]

    static func retryDelay(afterFailures count: Int?) -> TimeInterval {
        let failures = max(count ?? 1, 1)
        return retryStepsAfterFailure[min(failures, retryStepsAfterFailure.count) - 1]
    }

    /// When the next automatic attempt is allowed after a failure.
    static func nextAutomaticRetry(lastFailedAt: Date, failureCount: Int?) -> Date {
        lastFailedAt.addingTimeInterval(retryDelay(afterFailures: failureCount))
    }
    /// Same for an RTSP transmuxer that failed to start. Short, so a
    /// camera that reboots is back within seconds — but long enough to
    /// stop the respawn storm a dead camera caused while on screen
    /// (5 ffmpeg launches in 9 s, 2026-11-16).
    static let rtspRetryAfterFailure: TimeInterval = 30

    /// Expiry stamped in a googlevideo manifest URL (`…/expire/<epoch>/…`
    /// or `expire=<epoch>`), nil when there is none.
    static func expiry(ofResolvedURL url: String) -> Date? {
        for marker in ["/expire/", "expire="] {
            guard let range = url.range(of: marker) else { continue }
            let digits = url[range.upperBound...].prefix { $0.isNumber }
            if let epoch = TimeInterval(digits), epoch > 1_000_000_000 {
                return Date(timeIntervalSince1970: epoch)
            }
        }
        return nil
    }

    /// Whether a resolved URL can still be handed to the player.
    static func isUsable(resolvedURL: String?, resolvedAt: Date?, now: Date) -> Bool {
        guard let resolvedURL, !resolvedURL.isEmpty else { return false }
        let expires = expiry(ofResolvedURL: resolvedURL)
            ?? resolvedAt.map { $0.addingTimeInterval(assumedLifetime) }
        guard let expires else { return false }
        return now.addingTimeInterval(expiryMargin) < expires
    }

    /// Whether an automatic (non-forced) RTSP transmuxer start may run now.
    static func shouldStartTransmuxer(lastFailedAt: Date?, now: Date) -> Bool {
        guard let lastFailedAt else { return true }
        return now.timeIntervalSince(lastFailedAt) >= rtspRetryAfterFailure
    }

    /// Whether an automatic (non-forced) resolve should run now.
    static func shouldResolve(resolvedURL: String?, resolvedAt: Date?,
                              lastFailedAt: Date?, failureCount: Int? = nil, now: Date) -> Bool {
        if let lastFailedAt, now < nextAutomaticRetry(lastFailedAt: lastFailedAt, failureCount: failureCount) {
            return false
        }
        guard let resolvedURL, !resolvedURL.isEmpty, let resolvedAt else { return true }
        if now.timeIntervalSince(resolvedAt) >= refreshAfter { return true }
        return !isUsable(resolvedURL: resolvedURL, resolvedAt: resolvedAt, now: now)
    }
}

/// What to tell the user about a failed YouTube resolve: yt-dlp's raw
/// message says what happened, the hint says what to do about it.
enum LiveFeedResolveHint: Equatable {
    case botCheck
    case streamGone
    case toolMissing
    case other

    /// Classify the stored error text (yt-dlp's last `ERROR:` line, or
    /// our own launch-failure messages).
    static func classify(_ error: String) -> LiveFeedResolveHint {
        let text = error.lowercased()
        if text.contains("not a bot") || text.contains("sign in to confirm") { return .botCheck }
        if text.contains("yt-dlp is not installed") || text.contains("could not be launched") { return .toolMissing }
        if text.contains("not available") || text.contains("private video") || text.contains("has ended")
            || text.contains("been removed") || text.contains("unavailable") {
            return .streamGone
        }
        return .other
    }

    /// `installCommand` / `upgradeCommand`: the package-manager lines to
    /// suggest (Homebrew or MacPorts, decided by the caller).
    func text(installCommand: String, upgradeCommand: String) -> String {
        switch self {
        case .botCheck:
            return "YouTube is asking this Mac to sign in (bot check). It usually clears on its own; updating yt-dlp can help (\(upgradeCommand))."
        case .streamGone:
            return "This stream is no longer available on YouTube. Check the link."
        case .toolMissing:
            return "yt-dlp is missing. Install it with \(installCommand)."
        case .other:
            return "yt-dlp failed. Updating it often fixes this (\(upgradeCommand))."
        }
    }
}

/// The one sentence shown wherever a feed the wallpaper is skipping is
/// listed (popover playlist, Live Feeds panel).
enum LiveFeedDownMessage {
    static func text(retryAt: Date) -> String {
        "Feed down, will retry at \(retryAt.formatted(date: .omitted, time: .shortened))"
    }

    /// Popover line for a YouTube feed that has no playable URL because
    /// its resolve keeps failing.
    static let cannotResolve = "Can't resolve stream — check yt-dlp"

    /// Retry times still ahead, from the extension's status (feed id →
    /// seconds since 1970).
    static func pending(_ retryAt: [String: Double], now: Date = Date()) -> [String: Date] {
        retryAt.compactMapValues { epoch in
            let date = Date(timeIntervalSince1970: epoch)
            return date > now ? date : nil
        }
    }
}

struct LiveFeedsIndex: Codable {
    var version: Int
    var feeds: [LiveFeed]

    static let currentVersion = 1
    static let empty = LiveFeedsIndex(version: currentVersion, feeds: [])
}
