//
//  Thumbnails.swift
//  Aerial
//
//  Created by Guillaume Louel on 20/07/2020.
//  Copyright © 2020 Guillaume Louel. All rights reserved.
//

import Cocoa
import AVKit

/// Single still image per video, stored as `{video.id}.png` under
/// `Cache.thumbnailsPath`. Two production paths populate it:
///
/// 1. Primary — when the manifest publishes `previewImage`, the bytes
///    are downloaded and written verbatim. Fast, cheap, and the file
///    Apple intends for previews. ~900×580 PNG in practice.
/// 2. Legacy — `AVAssetImageGenerator` extracts the first frame from
///    the video itself, downscaled to `thumbSize`. Kept only for
///    sources that don't (yet) carry `previewImage`. The whole legacy
///    block is marked below and is meant to be deleted in one PR once
///    every source publishes the field.
struct Thumbnails {
    /// Fallback dimensions for the legacy first-frame path. Picked to
    /// stay slightly above the primary path's typical output (Apple
    /// serves `previewImage` around 214×130) so cards and inspector
    /// hero look consistent regardless of which source the video came
    /// from. 16:9 keeps the aspect of the video frame intact.
    private static let thumbSize = CGSize(width: 256, height: 144)

    // MARK: - Concurrency

    /// Coalesces concurrent `get(forVideo:)` requests for the same id.
    /// Without this, three views (browser grid + playlist strip + Now
    /// Playing card) asking for the same fresh thumb at once would
    /// each kick off a separate HTTP fetch / image extraction. The
    /// first caller does the work; later callers' completions are
    /// queued and all fire with the same result.
    private static let inFlightLock = NSLock()
    private static var inFlight: [String: [(NSImage?) -> Void]] = [:]

    // MARK: - Public API

    /// Returns the cached thumbnail if it exists on disk, or nil.
    /// Live feeds fall back to `LiveFeedThumbnailer`'s out-of-band
    /// frame grab under `Sources/Live Feeds/thumbs/`.
    static func cached(forVideo video: AerialVideo) -> NSImage? {
        let candidateThumb = getPath(forVideo: video)
        if FileManager.default.fileExists(atPath: candidateThumb) {
            return NSImage(contentsOfFile: candidateThumb)
        }
        if video.isLive {
            let livePath = Cache.supportPath
                .appending("/Sources/Live Feeds/thumbs/")
                .appending(video.id).appending(".jpg")
            if FileManager.default.fileExists(atPath: livePath) {
                return NSImage(contentsOfFile: livePath)
            }
        }
        return nil
    }

    /// Async thumbnail load. Returns the cached image if present;
    /// otherwise generates one (manifest preview download or legacy
    /// first-frame extraction) and returns the result. Always calls
    /// `completion` on the main queue.
    static func get(forVideo video: AerialVideo, _ completion: @escaping ((_ image: NSImage?) -> Void)) {
        DispatchQueue.global().async {
            if let thumb = cached(forVideo: video) {
                DispatchQueue.main.async { completion(thumb) }
                return
            }

            if video.isLive {
                // Live feeds' thumbnails are written by LiveFeedThumbnailer
                // (ffmpeg / yt-dlp). Don't try to extract a frame from a
                // live URL — it would block / fail.
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Coalesce concurrent requests for the same video.
            inFlightLock.lock()
            if inFlight[video.id] != nil {
                inFlight[video.id]?.append(completion)
                inFlightLock.unlock()
                return
            }
            inFlight[video.id] = [completion]
            inFlightLock.unlock()

            if video.isAvailableOffline || Cache.canNetwork() {
                generate(forVideo: video)
            }

            let result = cached(forVideo: video)

            inFlightLock.lock()
            let waiters = inFlight.removeValue(forKey: video.id) ?? []
            inFlightLock.unlock()

            DispatchQueue.main.async {
                for cb in waiters { cb(result) }
            }
        }
    }

    /// One-shot purge of the obsolete `{id}-large.jpg` files from
    /// before the single-file refactor. Idempotent — once the
    /// directory is clean, subsequent calls do nothing. Called from
    /// `AppDelegate.applicationDidFinishLaunching`.
    static func cleanupLegacyLargeFiles() {
        let path = Cache.thumbnailsPath
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        for name in entries where name.hasSuffix("-large.jpg") {
            try? FileManager.default.removeItem(atPath: (path as NSString).appendingPathComponent(name))
        }
    }

    // MARK: - Generation (private)

    private static func generate(forVideo video: AerialVideo) {
        if let raw = video.previewImage,
           !raw.isEmpty,
           let url = URL(string: raw) {
            generateFromManifestPreview(video, url: url)
        } else {
            // LEGACY: AVAssetImageGenerator fallback. Delete this
            // branch (and the LEGACY block at the bottom of this file)
            // once every source publishes `previewImage`.
            generateFromFirstFrame(video)
        }
    }

    /// Primary path: download the manifest-provided preview image and
    /// write its bytes verbatim. No re-encoding, no resizing — Apple
    /// already serves these at the right size and format (PNG).
    private static func generateFromManifestPreview(_ video: AerialVideo, url: URL) {
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                errorLog("Thumbnail preview download failed for \(video.id): \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                errorLog("Thumbnail preview HTTP \(http.statusCode) for \(video.id)")
            } else {
                resultData = data
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()

        guard let data = resultData, !data.isEmpty else { return }
        let saveURL = URL(fileURLWithPath: getPath(forVideo: video))
        do {
            try data.write(to: saveURL)
        } catch {
            errorLog("Thumbnail preview write failed for \(video.id): \(error.localizedDescription)")
        }
    }

    private static func getPath(forVideo video: AerialVideo) -> String {
        return Cache.thumbnailsPath.appending("/" + video.id + ".png")
    }

    // MARK: - LEGACY (delete when all sources publish previewImage)

    /// First-frame extraction via AVAssetImageGenerator. Same logic
    /// as the pre-refactor implementation, minus the second
    /// `-large.jpg` write.
    private static func generateFromFirstFrame(_ video: AerialVideo) {
        do {
            var asset: AVURLAsset
            if video.isAvailableOffline {
                // Cached file path — but Dolby Vision files break
                // AVAssetImageGenerator on cached reads, so for those
                // we still pull a 1080 SDR copy from the network.
                if (PrefsVideos.videoFormat == .v1080pHDR || PrefsVideos.videoFormat == .v4KHDR) && video.sourceFor(format: PrefsVideos.videoFormat).name.starts(with: "tvOS") {
                    asset = AVURLAsset(url: dolbyVisionFallbackURL(for: video))
                } else {
                    let path = VideoList.instance.localPathFor(video: video)
                    asset = AVURLAsset(url: URL(fileURLWithPath: path))
                }
            } else {
                if (PrefsVideos.videoFormat == .v1080pHDR || PrefsVideos.videoFormat == .v4KHDR) && video.sourceFor(format: PrefsVideos.videoFormat).name.starts(with: "tvOS") {
                    asset = AVURLAsset(url: dolbyVisionFallbackURL(for: video))
                } else {
                    asset = AVURLAsset(url: video.url)
                }
            }

            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)

            let saveURL = URL(fileURLWithPath: getPath(forVideo: video))
            try writeImage(image: NSImage(cgImage: cgImage, size: thumbSize),
                           usingType: .png,
                           withSizeInPixels: thumbSize,
                           to: saveURL)
        } catch {
            errorLog(error.localizedDescription)
        }
    }

    private static func dolbyVisionFallbackURL(for video: AerialVideo) -> URL {
        let urlHEVC = video.urls[.v1080pHEVC]
        let url264 = video.urls[.v1080pH264]
        if let hevc = urlHEVC, !hevc.isEmpty, let u = URL(string: hevc) { return u }
        if let h264 = url264, !h264.isEmpty, let u = URL(string: h264) { return u }
        return video.url
    }

    private static func unscaledBitmapImageRep(forImage image: NSImage) -> NSBitmapImageRep {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width),
            pixelsHigh: Int(image.size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            preconditionFailure()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func writeImage(
        image: NSImage,
        usingType type: NSBitmapImageRep.FileType,
        withSizeInPixels size: NSSize?,
        to url: URL) throws {
        if let size = size {
            image.size = size
        }
        let rep = unscaledBitmapImageRep(forImage: image)
        guard let data = rep.representation(using: type, properties: [.compressionFactor: 0.8]) else {
            preconditionFailure()
        }
        try data.write(to: url)
    }
}
