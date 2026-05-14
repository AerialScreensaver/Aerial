//
//  AerialVideo.swift
//  Aerial
//
//  Created by John Coates on 10/23/15.
//  Copyright © 2015 John Coates. All rights reserved.
//

import Cocoa
import AVFoundation

final class AerialVideo: CustomStringConvertible, Equatable {
    static func ==(lhs: AerialVideo, rhs: AerialVideo) -> Bool {
        return lhs.id == rhs.id // TODO && lhs.url1080pHEVC == rhs.url1080pHEVC
    }

    let id: String
    let name: String
    let secondaryName: String
    let type: String
    var timeOfDay: String
    let manifestTimeOfDay: String  // The value from the manifest, before any override
    let scene: SourceScene

    var urls: [VideoFormat: String]

    /// Every source that ships this video. Ordered: head is the primary
    /// (the manifest that first introduced the entry); subsequent
    /// entries are appended by `Source.parseVideoManifest` when a later
    /// manifest declares the same asset id. Never empty.
    /// Use `source` for primary-semantic accesses (cache path,
    /// `isCachable`, display); use `sources.contains(where:)` for
    /// membership-style queries (filter rules, source-name filters).
    var sources: [Source]

    /// Primary source — head of `sources`. Convenience for the many
    /// call sites that want "which manifest owns this entry" semantics
    /// (cache path, isCachable, sidebar grouping, inspector display).
    var source: Source { sources[0] }

    /// Which source contributed the URL for each format. Populated at
    /// init from the primary `source`, then amended by merges in
    /// `Source.parseVideoManifest` when another manifest patches in a
    /// URL that was missing. Lets the UI show, e.g., "4K HDR from tvOS
    /// 26" on a video whose base entry came from macOS 26.
    var urlSources: [VideoFormat: Source] = [:]

    /// Optional per-format MD5 digests, lowercase hex. When present,
    /// the download system verifies the file against this value after
    /// the move into cache and re-queues on mismatch. Empty / missing
    /// entries skip verification (same behaviour as before this field
    /// existed).
    var urlMD5s: [VideoFormat: String] = [:]
    let poi: [String: String]

    /// URL to a manifest-provided still image (typically ~900×580 PNG).
    /// When present, the thumbnail subsystem fetches this directly
    /// instead of running AVAssetImageGenerator on the video. Mutable
    /// so manifest-merge passes in `Source.parseVideoManifest` can
    /// patch it in if the existing entry was created from a source
    /// that lacked the field.
    var previewImage: String?

    var duration: Double

    var contentLength = 0

    var isVertical: Bool

    /// True when this entry is a live stream (RTSP, HLS, resolved YouTube live).
    /// Live entries play for `livePlaybackSeconds` then rotate; they have no
    /// finite duration, no cache, and no fade observer.
    let isLive: Bool

    /// How long (seconds) to play a live stream before advancing. Default 300.
    let livePlaybackSeconds: Double

    var isAvailableOffline: Bool {
        // Live streams don't get cached; treat them as always "available" so
        // the playlist machinery doesn't filter them out.
        if isLive { return true }
        return VideoCache.isAvailableOffline(video: self)
    }

    // MARK: - Public getter
    var url: URL {
        return getClosestAvailable(wanted: preferredFormat())
    }

    /// Per-video format, if the user has pinned one; otherwise the
    /// global `PrefsVideos.videoFormat`. Consulted by every downstream
    /// caller that hits `url` / `effectiveFormat()` / cache / download.
    func preferredFormat() -> VideoFormat {
        if let raw = PrefsVideos.videoFormatOverride[id],
           let overridden = VideoFormat(rawValue: raw) {
            return overridden
        }
        return PrefsVideos.videoFormat
    }

    // Returns the closest video we have in the manifests
    private func getClosestAvailable(wanted: VideoFormat) -> URL {
        if urls[wanted] != "" && urls[wanted] != nil {
            return getURL(string: urls[wanted]!)
        } else {
            // Fallback
            if urls.keys.contains(.v4KHEVC), urls[.v4KHEVC] != "" {
                return getURL(string: urls[.v4KHEVC]!)
            } else if urls.keys.contains(.v4KSDR240), urls[.v4KSDR240] != "" {
                // macOS manifest only have those
                return getURL(string: urls[.v4KSDR240]!)
            } else if urls.keys.contains(.v1080pHEVC), urls[.v1080pHEVC] != "" {
                return getURL(string: urls[.v1080pHEVC]!)
            } else if urls.keys.contains(.v1080pH264), urls[.v1080pH264] != "" { // Last resort
                return getURL(string: urls[.v1080pH264]!)
            } else {
                errorLog("getClosestAvailable failed back hard to 4KHDR")
                // Something went very wrong if we are here
                return getURL(string: urls[.v4KHDR]!)
            }
        }
    }
    private func getURL(string: String) -> URL {
        if string.starts(with: "/") {
            return URL(fileURLWithPath: string)
        } else {
            return URL(string: string)!
        }
    }

    // swiftlint:disable cyclomatic_complexity
    // MARK: - Init
    init(id: String,
         name: String,
         secondaryName: String,
         type: String,
         timeOfDay: String,
         scene: String,
         urls: [VideoFormat: String],
         sources: [Source],
         poi: [String: String],
         md5s: [VideoFormat: String] = [:],
         isLive: Bool = false,
         livePlaybackSeconds: Double = 300,
         previewImage: String? = nil
    ) {
        self.isLive = isLive
        self.livePlaybackSeconds = livePlaybackSeconds
        self.id = id

        // We override names for known space videos
        if SourceInfo.seaVideos.contains(id) {
            self.name = "Sea"
            if secondaryName != "" {
                self.secondaryName = secondaryName
            } else {
                self.secondaryName = name
            }
        } else if SourceInfo.spaceVideos.contains(id) {
            self.name = "Space"
            if secondaryName != "" {
                self.secondaryName = secondaryName
            } else {
                self.secondaryName = name
            }
        } else {
            // We align to the new jsons...
            if name == "New York City" {
                self.name = "New York"
            } else {
                self.name = name
            }
            self.secondaryName = secondaryName      // We may have a secondary name from our merges too now !
        }

        self.type = type
        self.manifestTimeOfDay = timeOfDay  // Save raw manifest value

        // Priority: user override > SourceInfo hardcoded > manifest value
        if let userOverride = PrefsVideos.timeOfDayOverride[id] {
            self.timeOfDay = userOverride
        } else if let val = SourceInfo.timeInformation[id] {
            self.timeOfDay = val
        } else {
            self.timeOfDay = timeOfDay
        }

        switch scene {
        case "sea":
            self.scene = .sea
        case "space":
            self.scene = .space
        case "city":
            self.scene = .city
        case "countryside":
            self.scene = .countryside
        case "beach":
            self.scene = .beach
        default:
            self.scene = .nature
        }

        self.urls = urls
        self.sources = sources
        // Seed per-format provenance from the primary source constructing
        // this video. Merges in `Source.parseVideoManifest` will overwrite
        // individual entries when a later source patches in a URL.
        for (format, url) in urls where url != "" {
            self.urlSources[format] = sources[0]
        }
        // Seed per-format MD5s from the source constructing this video.
        // Merges in `Source.parseVideoManifest` patch missing-URL slots
        // and update urlMD5s in lockstep so a later source's checksum
        // wins for the format whose URL it provided.
        self.urlMD5s = md5s
        self.poi = poi
        self.previewImage = previewImage

        // Default stuff, we double check those below
        self.duration = 0
        self.isVertical = false

        updateDuration()    // We need to have the video duration
    }



    
    func updateDuration() {
        // We need to retrieve video duration from the cached files.
        // This is a workaround as currently, the VideoCache infrastructure
        // relies on AVAsset with an external URL all the time, even when
        // working on a cached copy which makes the native duration retrieval fail
        //
        // And... we also check the orientation now too ;)

        // Live streams are indefinite; rotation is timer-driven, not
        // based on duration. Skip the AVAsset probe entirely.
        if isLive {
            self.duration = 0
            return
        }

        let fileManager = FileManager.default

        if let duration = PrefsVideos.durationCache[self.id] {
            // debugLog("Using cache duration : \(duration)")
            self.duration = duration
            return
        }

        // With custom videos, we may already store the local path
        // If so, check it
        if self.url.absoluteString.starts(with: "file") {
            if fileManager.fileExists(atPath: self.url.path) {
                let asset = AVAsset(url: self.url)
                self.duration = CMTimeGetSeconds(asset.duration)
                self.isVertical = asset.isVertical()
            } else {
                errorLog("Custom video is missing : \(self.url.path)")
                self.duration = 0
            }
        } else {
            // If not, iterate through all possible versions to see if any is cached
            for format in VideoFormat.allCases {
                // swiftlint:disable:next for_where
                if urls[format] != "" {

                    let path = VideoList.instance.localPathFor(video: self)

                    if fileManager.fileExists(atPath: path) {
                        let asset = AVAsset(url: URL(fileURLWithPath: path))
                        self.duration = CMTimeGetSeconds(asset.duration)

                        // debugLog("Caching video duration")
                        PrefsVideos.durationCache[self.id] = self.duration

                        return
                    }
                }
            }
        }
    }

    /// The `VideoFormat` that `getClosestAvailable` will actually
    /// resolve for `PrefsVideos.videoFormat`. The ladder matches
    /// `getClosestAvailable` so UI labels agree with what AVPlayer
    /// streams, including the 4K 240fps tier that `getBestFormat`
    /// used to skip.
    func effectiveFormat() -> VideoFormat {
        let wanted = preferredFormat()
        if let url = urls[wanted], url != "" {
            return wanted
        }
        let fallback: [VideoFormat] = [.v4KHEVC, .v4KSDR240, .v1080pHDR, .v1080pHEVC, .v1080pH264, .v4KHDR]
        for fmt in fallback {
            if let url = urls[fmt], url != "" {
                return fmt
            }
        }
        return wanted
    }

    /// Which source contributed the URL for `format`. Falls back to
    /// the video's primary `source` for formats missing from
    /// `urlSources` (e.g. local sources or older merged entries).
    func sourceFor(format: VideoFormat) -> Source {
        return urlSources[format] ?? source
    }

    static func label(for format: VideoFormat) -> String {
        switch format {
        case .v4KHDR: return "4K HDR"
        case .v1080pH264: return "1080p"
        case .v1080pHEVC: return "1080p"
        case .v1080pHDR: return "1080p HDR"
        case .v4KHEVC: return "4K"
        case .v4KSDR240: return "4K 240FPS"
        }
    }

    var description: String {
        return """
        id=\(id),
        name=\(name),
        type=\(type),
        timeofDay=\(timeOfDay),
        urls=\(urls)
        """
    }
}
