//
//  VideoList.swift
//  Aerial
//
//  Created by Guillaume Louel on 08/07/2020.
//  Copyright © 2020 Guillaume Louel. All rights reserved.
//

import Foundation

typealias VideoListRefreshCallback = () -> Void
extension RangeReplaceableCollection {
    /// Returns a collection containing, in order, the first instances of
    /// elements of the sequence that compare equally for the keyPath.
    func unique<T: Hashable>(for keyPath: KeyPath<Element, T>) -> Self {
        var unique = Set<T>()
        return filter { unique.insert($0[keyPath: keyPath]).inserted }
    }
}

// swiftlint:disable:next type_body_length
class VideoList {
    enum FilterMode {
        case location, cache, time, scene, source, rotation, favorite, hidden
    }

    static let instance: VideoList = VideoList()
    var callbacks = [VideoListRefreshCallback]()

    var videos: [AerialVideo] = []

    /// Optional override for video selection. When set (by PlaylistManager under Companion),
    /// randomVideo() delegates to this closure instead of using the in-memory playlist.
    /// Parameters: (excluding, isVertical, screenUUID) -> (video, shouldLoop)
    var nextVideoOverride: (([AerialVideo], Bool, String?) -> (AerialVideo?, Bool))?

    /// Sibling override for backward navigation. When set (by
    /// PlaylistManager under Companion), `ExtensionVideoLoader.popPreviousFromPlaylist`
    /// delegates to this closure so the previous-direction state is
    /// kept in sync with the same source of truth that drives `nextVideoOverride`.
    /// Without this, the two managers diverge after the user mixes
    /// next / previous calls.
    /// Parameters: (screenUUID) -> (video, shouldLoop)
    var previousVideoOverride: ((String?) -> (AerialVideo?, Bool))?

    // OLD Playlist management
    var playlistIsRestricted = false
    var playlistRestrictedTo = ""
    var playlistHasVerticalVideos = false
    var playlist = [AerialVideo]()
    var lastPluckedFromPlaylist: AerialVideo?

    let cacheDownloaded = "Downloaded"
    let cacheOnline = "Online"
    init() {
        DispatchQueue.main.async {
            self.downloadManifestsIfNeeded()
        }
    }

    // This is used to grab the correct path depending on whether a source is cacheable or not
    func localPathFor(video: AerialVideo) -> String {
        if video.source.isCachable {
            return VideoCache.cachePath(forVideo: video) ?? ""
        } else {
            return VideoCache.sourcePathFor(video)
        }
    }

    // MARK: - Helpers for the various filterings
    private func cacheSources() -> [String] {
        var cache: [String] = []

        if !videos.filter({ $0.isAvailableOffline && !PrefsVideos.hidden.contains($0.id) }).isEmpty {
            cache.append(cacheDownloaded)
        }
        if !videos.filter({ !$0.isAvailableOffline && !PrefsVideos.hidden.contains($0.id) }).isEmpty {
            cache.append(cacheOnline)
        }

        return cache
    }

    private func sourcesFor(_ mode: FilterMode) -> [String] {
        switch mode {
        case .location:
            return videos.filter { !PrefsVideos.hidden.contains($0.id) }.map { $0.name }.unique(for: \.self).sorted()
        case .time:
            return videos.filter { !PrefsVideos.hidden.contains($0.id) }.map { $0.timeOfDay.capitalizeFirstLetter() }.unique(for: \.self).sorted()
        case .scene:
            return videos.filter { !PrefsVideos.hidden.contains($0.id) }.map { $0.scene.rawValue.capitalizeFirstLetter() }.unique(for: \.self).sorted()
        case .source:
            return videos.filter { !PrefsVideos.hidden.contains($0.id) }.flatMap { $0.sources }.map { $0.name }.unique(for: \.self).sorted()
        case .cache:
            return cacheSources()
        case .rotation:
            return ["On Rotation"]
        case .favorite:
            return ["Favorites"]
        case .hidden:
            return ["Hidden"]
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func filteredVideosFor(_ mode: FilterMode, filter: [String]) -> [AerialVideo] {
        // Our preference filters contains ALL sorts of filters (location, time) that are
        // saved for better user experience. So we need to filter the filters first !
        var filters: [String] = []

        for afilter in filter {
            switch mode {
            case .location:
                if afilter.starts(with: "location") {
                    filters.append(afilter.split(separator: ":")[1].lowercased())
                }
            case .cache:
                filters.append(afilter.lowercased())
            case .time:
                if afilter.starts(with: "time") {
                    filters.append(afilter.split(separator: ":")[1].lowercased())
                }
            case .scene:
                if afilter.starts(with: "scene") {
                    filters.append(afilter.split(separator: ":")[1].lowercased())
                }
            case .source:
                if afilter.starts(with: "source") {
                    filters.append(afilter.split(separator: ":")[1].lowercased())
                }
            case .rotation:
                filters.append(afilter.lowercased())
            case .favorite:
                filters.append(afilter.lowercased())
            case .hidden:
                filters.append(afilter.lowercased())
            }
        }

        switch mode {
        case .location:
            let vids = videos
                .filter { filters.contains($0.name.lowercased()) && !PrefsVideos.hidden.contains($0.id) }
                .sorted { $0.secondaryName < $1.secondaryName }
            return vids
        case .time:
            return videos
                .filter { filters.contains($0.timeOfDay.lowercased()) && !PrefsVideos.hidden.contains($0.id) }
                .sorted { $0.secondaryName < $1.secondaryName }
        case .scene:
            return videos
                .filter { filters.contains($0.scene.rawValue.lowercased()) && !PrefsVideos.hidden.contains($0.id) }
                .sorted { $0.secondaryName < $1.secondaryName }
        case .source:
            return videos
                .filter { video in
                    video.sources.contains(where: { filters.contains($0.name.lowercased()) })
                        && !PrefsVideos.hidden.contains(video.id)
                }
                .sorted { $0.secondaryName < $1.secondaryName }
        case .favorite:
            return videos
                .filter { PrefsVideos.favorites.contains($0.id) && !PrefsVideos.hidden.contains($0.id) }
                .sorted { $0.secondaryName < $1.secondaryName }
        case .hidden:
            return videos
                .filter { PrefsVideos.hidden.contains($0.id) }
                .sorted { $0.secondaryName < $1.secondaryName }
        default:
            return videos
                .filter({ $0.isAvailableOffline })
                .sorted { $0.secondaryName < $1.secondaryName }
        }
    }

    // MARK: - Public getters to filter the list
    func getSources(mode: FilterMode) -> [String] {
        return sourcesFor(mode)
    }

    // MARK: - Callbacks
    func addCallback(_ callback:@escaping VideoListRefreshCallback) {
        callbacks.append(callback)

        // We may need to insta callback if we were already inited
        if !videos.isEmpty {
            callback()
        }
    }

    /// Force-refresh a single source by name. Used by the per-source Refresh
    /// button so clicking it only re-fetches the manifest the user is looking
    /// at, instead of iterating every source in `SourceList.list`. Bypasses
    /// the `shouldCheckForNewVideos()` periodicity gate but still requires
    /// network and a fetchable source type. Does NOT stamp `lastVideoCheck`
    /// — a per-source ad-hoc check shouldn't defer the global auto-refresh.
    func reloadSource(named name: String) {
        guard let source = SourceList.list.first(where: { $0.name == name }) else {
            debugLog("reloadSource: no source named '\(name)'")
            return
        }
        guard source.type != .local, source.type != .live else {
            debugLog("reloadSource: \(name) is not network-fetchable (type \(source.type))")
            return
        }
        guard source.isEnabled() else {
            debugLog("reloadSource: \(name) is disabled, skipping")
            return
        }
        guard let manifestURL = URL(string: source.manifestUrl) else {
            errorLog("reloadSource: \(name) has invalid manifestUrl (\(source.manifestUrl))")
            return
        }
        guard Cache.canNetwork() else {
            debugLog("reloadSource: \(name) skipped — no network")
            return
        }

        debugLog("\(name) force-refreshing single source")
        let downloadManager = DownloadManager()
        let operation = downloadManager.queueDownload(manifestURL, folder: source.name)
        let completion = BlockOperation {
            self.refreshVideoList()
        }
        completion.addDependency(operation)
        OperationQueue.main.addOperation(completion)
    }

    // This is how we force a source refresh, it will trigger various callbacks when done
    // (e.g. to refresh video list in the ui)
    //
    // Pass `force: true` to bypass the `PrefsVideos.shouldCheckForNewVideos()`
    // periodicity gate — used by the manual "Refresh" button so it actually
    // re-fetches manifests instead of deferring to the weekly/monthly window.
    func reloadSources(force: Bool = false) {
        // Populate `videos` synchronously from cached manifests first so callers
        // (notably the screensaver extension's ExtensionVideoLoader) see a
        // populated list immediately, rather than racing against async manifest
        // downloads. Callbacks are suppressed here; the final refresh after
        // downloads complete (or the synchronous refresh when nothing needs
        // fetching) will fire them.
        refreshVideoList(fireCallbacks: false)
        downloadManifestsIfNeeded(force: force)
    }

    private func downloadManifestsIfNeeded(force: Bool = false) {
        let downloadManager = DownloadManager()

        var sourceQueue: [Source] = []

        let completion = BlockOperation {
            self.refreshVideoList()
        }

        // Let's check our sources first
        for source in SourceList.list {
            // Local sources are scanned by the updateLocalSource loop below and
            // have no network manifest to fetch. Queuing them here would pass a
            // schemeless path ("/Users/Shared/Aerial/My Videos") to URLSession
            // and log a spurious NSURLErrorUnsupportedURL (-1002).
            //
            // Live Feeds (.live) are synthesized locally by LiveFeedsSourceSync
            // and have an empty manifestUrl — they're not fetchable either.
            guard source.type != .local, source.type != .live else { continue }

            // But only the enabled ones
            if source.isEnabled() {
                // We may need to download it
                if !source.isCached() {
                    debugLog("\(source.name) is not cached, downloading...")
                    sourceQueue.append(source)
                } else if (force || PrefsVideos.shouldCheckForNewVideos()) && Cache.canNetwork() {
                    debugLog("\(source.name) looking for updated manifest\(force ? " (forced)" : "")...")
                    sourceQueue.append(source)
                }
            }
        }

        for source in SourceList.list {
            if source.type == .local {
                debugLog("\(source.name) updating local source")
                SourceList.updateLocalSource(source: source, reload: false)
            }
        }

        if !sourceQueue.isEmpty {
            var didQueue = false
            // Now queue and download
            for source in sourceQueue {
                guard let manifestURL = URL(string: source.manifestUrl) else {
                    errorLog("Skipping \(source.name): manifestUrl is not a valid URL (\(source.manifestUrl))")
                    continue
                }
                let operation = downloadManager.queueDownload(manifestURL, folder: source.name)
                completion.addDependency(operation)
                didQueue = true

                // Mark that we updated our sources
                PrefsVideos.saveLastVideoCheck()
            }

            if didQueue {
                OperationQueue.main.addOperation(completion)
            } else {
                refreshVideoList()
            }
        } else {
            refreshVideoList()
        }
    }
    //#endif

    // This is called when all our files are downloaded
    private func refreshVideoList(fireCallbacks: Bool = true) {
        videos = []

        for source in SourceList.list {
            if source.isEnabled() {
                // We may need to download it
                if source.isCached() {
                    let vids = source.getVideos()
                    videos.append(contentsOf: vids)
                }
            }
        }

        videos = videos.sorted { $0.name < $1.name }

        // Let everyone who wants to know that our list is updated
        if fireCallbacks {
            for callback in callbacks {
                callback()
            }
        }
    }

    // MARK: - New rotation management
    /// Drops `source:<name>` entries that don't belong to the active
    /// grouping: in `.source` mode we keep only built-in / "My Videos";
    /// in `.expansions` mode we keep only non-built-ins. Other prefixes
    /// (location:, time:, scene:, …) pass through unchanged so existing
    /// non-source modes are unaffected.
    private static func partitionSourceFilterStrings(_ strings: [String],
                                                     forMode mode: NewShouldPlay) -> [String] {
        guard mode == .source || mode == .expansions else { return strings }
        return strings.filter { afilter in
            guard afilter.starts(with: "source:") else { return true }
            let name = String(afilter.dropFirst("source:".count))
            let isBuiltIn = name.hasPrefix("tvOS") || name.hasPrefix("macOS") || name == "My Videos"
            switch mode {
            case .source:     return isBuiltIn
            case .expansions: return !isBuiltIn && name != "Live Feeds"
            default:          return true
            }
        }
    }

    func currentRotation() -> [AerialVideo] {
        var mode: FilterMode
        switch PrefsVideos.newShouldPlay {
        case .location:
            mode = .location
        case .time:
            mode = .time
        case .scene:
            mode = .scene
        case .source, .expansions:
            // Expansions reuse source-name filtering; the picker just
            // partitions which source names appear in each grouping.
            mode = .source
        default:
            mode = .cache
        }

        switch PrefsVideos.newShouldPlay {
/*        case .everything:
            return videos
                .filter({ !PrefsVideos.hidden.contains($0.id) })
                .sorted { $0.secondaryName < $1.secondaryName }*/
        case .favorites:
            return videos
                .filter({ PrefsVideos.favorites.contains($0.id) && !PrefsVideos.hidden.contains($0.id) })
                .sorted { $0.secondaryName < $1.secondaryName }
        case .liveFeeds:
            return videos
                .filter({ $0.isLive && !PrefsVideos.hidden.contains($0.id) })
                .sorted { $0.secondaryName < $1.secondaryName }
        default:
            let strings = Self.partitionSourceFilterStrings(PrefsVideos.newShouldPlayString,
                                                            forMode: PrefsVideos.newShouldPlay)
            return filteredVideosFor(mode, filter: strings)
        }
    }
    
    func everythingRotation() -> [AerialVideo] {
        return videos
            .filter({ !PrefsVideos.hidden.contains($0.id) })
            .sorted { $0.secondaryName < $1.secondaryName }
    }

    // MARK: - Public filter for PlaylistManager / DownloadCoordinator

    /// Returns videos matching the given filter mode and strings, mirroring currentRotation() logic
    /// but with explicit parameters instead of reading from prefs.
    func videosMatchingFilter(mode: NewShouldPlay, filterStrings: [String]) -> [AerialVideo] {
        switch mode {
        case .favorites:
            return videos
                .filter { PrefsVideos.favorites.contains($0.id) && !PrefsVideos.hidden.contains($0.id) }
                .sorted { $0.secondaryName < $1.secondaryName }
        case .liveFeeds:
            // All live feed entries, regardless of filterStrings — the user's
            // Live Feeds library is the authoritative scope.
            return videos
                .filter { $0.isLive && !PrefsVideos.hidden.contains($0.id) }
                .sorted { $0.secondaryName < $1.secondaryName }
        default:
            var filterMode: FilterMode
            switch mode {
            case .location: filterMode = .location
            case .time:     filterMode = .time
            case .scene:    filterMode = .scene
            case .source, .expansions: filterMode = .source
            default:        filterMode = .cache
            }
            let strings = Self.partitionSourceFilterStrings(filterStrings, forMode: mode)
            return filteredVideosFor(filterMode, filter: strings)
        }
    }

    // MARK: - Playlist management
    func generatePlaylist(isRestricted: Bool, restrictedTo: String, isVertical: Bool) {
        debugLog("generate playlist (isVertical: \(isVertical)")
        // Start fresh
        playlist = [AerialVideo]()
        playlistIsRestricted = isRestricted
        playlistRestrictedTo = restrictedTo
        playlistHasVerticalVideos = false

        var shuffled = currentRotation().shuffled()

        // If we have nothing, just get everything
        if shuffled.count == 0 {
            shuffled = everythingRotation().shuffled()
        }
        
        let cachedShuffled = shuffled.filter({ $0.isAvailableOffline })

        
        debugLog("Playlist raw count: \(shuffled.count) raw cached count \(cachedShuffled.count) isRestricted: \(isRestricted) restrictedTo: \(restrictedTo)")

        if PrefsDisplays.viewingMode == .independent && PrefsAdvanced.favorOrientation {
            // We check cached videos only as those are the only ones for which we know the orientation
            for video in cachedShuffled {
                // swiftlint:disable:next for_where
                if video.isVertical {
                    playlistHasVerticalVideos = true
                    debugLog(">>> Playlist contains vertical videos (favoring ON)")
                }
            }
        }

        for video in shuffled {
            /*
            // Do we restrict videos by screen orientation ?
            if restrictOrientation {
                print(video.url)
                print(video.isVertical)
                if !video.isVertical && isVertical {
                    // Block landscape videos on vertical screens
                    continue
                } else if video.isVertical && !isVertical {
                    // Block portrait videos on horizontal screens
                    continue
                }
            }*/

            // Do we restrict video types by day/night ?
            if isRestricted {
                if video.timeOfDay != restrictedTo {
                    continue
                }
            }

            if !video.isAvailableOffline {
                continue
            }

            // All good ? Add to playlist
            playlist.append(video)
        }

        debugLog("Final count : \(playlist.count)")
        // On regenerating a new playlist, we try to avoid repeating the last thing we played!
        while playlist.count > 1 && lastPluckedFromPlaylist == playlist.first {
            playlist.shuffle()
        }
    }

    func randomVideo(excluding: [AerialVideo], isVertical: Bool, screenUUID: String? = nil) -> (AerialVideo?, Bool) {
        // If PlaylistManager has installed an override (Companion desktop mode), use it
        if let override = nextVideoOverride {
            let result = override(excluding, isVertical, screenUUID)
            if result.0 != nil {
                return result
            }
            // Fall through to normal behavior if override returned nil
        }

        var shouldLoop = false
        let timeManagement = TimeManagement.sharedInstance

        let (shouldRestrictByDayNight, restrictTo) = timeManagement.shouldRestrictPlaybackToDayNightVideo()

        // Do we still have a video in the correct format in the playlist?
        var needOrientedVideo = false
        if playlistHasVerticalVideos && !playlist.isEmpty {
            needOrientedVideo = true
            for video in playlist {
                if isVertical && video.isVertical {
                    needOrientedVideo = false
                } else if !isVertical && !video.isVertical {
                    needOrientedVideo = false
                }
            }
        }

        debugLog("remaining in playlist : \(playlist.count) needOrientedVideo : \(needOrientedVideo)")

        // We may need to regenerate a playlist!
        if playlist.isEmpty || restrictTo != playlistRestrictedTo || shouldRestrictByDayNight != playlistIsRestricted || needOrientedVideo {
            generatePlaylist(isRestricted: shouldRestrictByDayNight, restrictedTo: restrictTo, isVertical: isVertical)
            if playlist.count == 1 {
                debugLog("playlist only has one element, looping!")
                shouldLoop = true
            }
        }

        // If not pluck one from current playlist and return that
        if !playlist.isEmpty {
            if playlistHasVerticalVideos {
                lastPluckedFromPlaylist = pluckOrientedVideo(isVertical: isVertical)
            } else {
                lastPluckedFromPlaylist = playlist.removeFirst()
            }

            return (lastPluckedFromPlaylist, shouldLoop)
        } else {
            // If we don't have any playlist, something's got awfully wrong so deal with that!
            return (findBestEffortVideo(), shouldLoop)
        }
    }

    func pluckOrientedVideo(isVertical: Bool) -> AerialVideo? {
        // Grab first one corresponding to orientation
        lastPluckedFromPlaylist = playlist.first(where: { $0.isVertical == isVertical })!
        debugLog("lastplucked")

        // And actually remove it
        debugLog("pre pluck \(playlist.count)")
        playlist = playlist.filter { $0 != lastPluckedFromPlaylist }
        debugLog("post pluck \(playlist.count)")

        return lastPluckedFromPlaylist
    }

    // Find a backup plan when conditions are not met
    func findBestEffortVideo() -> AerialVideo? {
        // So this is embarassing. This can happen if :
        // - No video checked
        // - No video for current conditions (only day video checked, and looking for night)
        // - We don't want to stream but don't have any video
        // - We may not have the manifests
        // At this point we're doing a best effort :
        // - Did we play something previously ? If so play that back (will loop)
        // - return a random one from the manifest that is cached
        // - return a random video that is not cached (slight betrayal of the Never stream videos)

        warnLog("Empty playlist, not good !")

        if lastPluckedFromPlaylist != nil {
            warnLog("Repeating last played video, after condition change not met !")
            return lastPluckedFromPlaylist!
        } else {
            // Start with a shuffled list
            let shuffled = videos.shuffled()

            if shuffled.isEmpty {
                // This is super bad, no manifest at all
                errorLog("No manifest, nothing to play !")
                return nil
            }

            for video in shuffled {
                // If we find anything cached and in rotation, we send that back
                if video.isAvailableOffline && currentRotation().contains(video) {
                    warnLog("returning random cached in rotation video after condition change not met !")
                    return video
                }
            }

            // We try to return something that's at least in the rotation, if there is one
            if !currentRotation().isEmpty {
                warnLog("returning random non cached BUT in rotation video after condition change not met !")
                return currentRotation().shuffled().first
            }

            // Really nothing ? I can't even !
            warnLog("returning truly random video after condition change not met !")
            return shuffled.first!
        }
    }

}
