//
//  LiveFeedManager.swift
//  Aerial
//
//  Companion-only singleton managing the user's configured live feeds.
//  Persists to /Users/Shared/Aerial/live-feeds.json, following the
//  project convention. The extension-visible playback URLs are written
//  separately into the "Live Feeds" source folder by LiveFeedsSourceSync.
//  RTSP credentials (Phase 4) must use Keychain rather than this file.
//

import Foundation

final class LiveFeedManager {

    // MARK: - Singleton

    static let shared = LiveFeedManager()

    // MARK: - Notifications

    static let didChangeNotification = Notification.Name("com.glouel.aerial.liveFeedsDidChange")

    /// Fired when a feed's async resolution (yt-dlp, ffmpeg transmuxer)
    /// fails. `userInfo["feedID"]` is the UUID as a String;
    /// `userInfo["error"]` is the human-readable error message.
    static let resolutionFailedNotification = Notification.Name("com.glouel.aerial.liveFeedResolutionFailed")

    // MARK: - Storage

    /// /Users/Shared/Aerial/live-feeds.json
    static var indexURL: URL {
        URL(fileURLWithPath: Cache.supportPath, isDirectory: true)
            .appendingPathComponent("live-feeds.json")
    }

    private let store = JSONPreferencesStore.shared
    private var cache: LiveFeedsIndex
    private let queue = DispatchQueue(label: "com.glouel.aerial.livefeeds", attributes: .concurrent)

    private init() {
        if let loaded = JSONPreferencesStore.shared.read(LiveFeedsIndex.self, from: Self.indexURL) {
            cache = loaded
        } else {
            cache = .empty
        }

        // The RTSP loopback URL persisted in live-feeds.json is valid only
        // for the session that wrote it — LiveFeedsGateway takes an
        // ephemeral port each launch. Wipe these so LiveFeedsSourceSync
        // omits RTSP feeds from entries.json until a fresh transmuxer is
        // spawned on demand (pre-warm, preview, reload).
        var wipedStaleRTSP = false
        for i in cache.feeds.indices where cache.feeds[i].kind == .rtsp {
            if cache.feeds[i].resolvedURL != nil || cache.feeds[i].resolvedAt != nil {
                cache.feeds[i].resolvedURL = nil
                cache.feeds[i].resolvedAt = nil
                wipedStaleRTSP = true
            }
        }
        if wipedStaleRTSP {
            store.write(cache, to: Self.indexURL)
        }
    }

    // MARK: - Read

    func allFeeds() -> [LiveFeed] {
        queue.sync { cache.feeds }
    }

    func feed(id: UUID) -> LiveFeed? {
        queue.sync { cache.feeds.first(where: { $0.id == id }) }
    }

    // MARK: - Write

    @discardableResult
    func add(displayName: String, sourceURL: String, kind: LiveFeedKind? = nil, playbackSeconds: Double = 300) -> LiveFeed {
        // Strip any `user:pass@` fragment from the URL before it hits
        // disk; the credential half goes to Keychain under the feed id.
        let (cleanedURL, creds) = LiveFeedCredentialStore.extractCredentials(from: sourceURL)
        let feed = LiveFeed(displayName: displayName,
                            sourceURL: cleanedURL,
                            kind: kind,
                            playbackSeconds: playbackSeconds)
        if creds != nil {
            LiveFeedCredentialStore.save(credentials: creds, for: feed.id)
        }
        queue.sync(flags: .barrier) {
            cache.feeds.append(feed)
            persistLocked()
        }
        syncAndNotify()
        LiveFeedResolver.shared.resolveIfNeeded(feed, force: true)
        LiveFeedThumbnailer.shared.ensureThumbnail(for: feed)
        return feed
    }

    func update(_ feed: LiveFeed) {
        // Same strip/stash pattern as `add` — if the user edits the URL
        // and types new credentials inline, they shouldn't land on disk.
        let (cleanedURL, creds) = LiveFeedCredentialStore.extractCredentials(from: feed.sourceURL)
        var cleaned = feed
        cleaned.sourceURL = cleanedURL
        if creds != nil {
            LiveFeedCredentialStore.save(credentials: creds, for: cleaned.id)
        }

        var previous: LiveFeed?
        queue.sync(flags: .barrier) {
            guard let idx = cache.feeds.firstIndex(where: { $0.id == cleaned.id }) else { return }
            previous = cache.feeds[idx]
            cache.feeds[idx] = cleaned
            persistLocked()
        }
        syncAndNotify()
        // Regenerate the thumbnail when the URL changes — the previous
        // one might point to a different stream entirely.
        if previous?.sourceURL != cleaned.sourceURL {
            LiveFeedThumbnailer.shared.ensureThumbnail(for: cleaned, force: true)
        }
    }

    func remove(id: UUID) {
        var removed: LiveFeed?
        queue.sync(flags: .barrier) {
            removed = cache.feeds.first(where: { $0.id == id })
            cache.feeds.removeAll { $0.id == id }
            persistLocked()
        }
        // Tear down any running transmuxer and delete its HLS segment
        // directory — otherwise we'd leak both the ffmpeg process and
        // the files on disk.
        LiveFeedTransmuxerManager.shared.stop(feedID: id)
        LiveFeedCredentialStore.delete(for: id)
        if let feed = removed {
            LiveFeedThumbnailer.shared.remove(for: feed)
        }
        syncAndNotify()
    }

    /// Write the resolved playback URL (and timestamp) for a feed.
    /// Called by `LiveFeedResolver` after `yt-dlp -g` succeeds.
    func updateResolution(id: UUID, resolvedURL: String?, resolvedAt: Date?) {
        queue.sync(flags: .barrier) {
            guard let idx = cache.feeds.firstIndex(where: { $0.id == id }) else { return }
            cache.feeds[idx].resolvedURL = resolvedURL
            cache.feeds[idx].resolvedAt = resolvedAt
            persistLocked()
        }
        syncAndNotify()
    }

    // MARK: - Private

    private func persistLocked() {
        // Cache.supportPath ensures /Users/Shared/Aerial/ exists on every
        // access, so no separate directory creation is needed here.
        store.write(cache, to: Self.indexURL)
    }

    private func syncAndNotify() {
        // Regenerate the shared source folder the extension reads, then
        // bounce the VideoList so the new/removed entries show up in the UI.
        LiveFeedsSourceSync.shared.sync(feeds: allFeeds())
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }
}
