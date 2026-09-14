//
//  VideoCache.swift
//  Aerial
//
//  Created by John Coates on 10/29/15.
//  Copyright © 2015 John Coates. All rights reserved.
//
//  Used to be the in-memory streaming cache that fed
//  AVAssetResourceLoadingRequest with byte ranges as they came off the
//  wire. The appex rewrite (post-Aerial-3) downloads complete files via
//  `DownloadCoordinator` and AVPlayer reads them from the local file
//  directly, so the entire instance side of this class is dead. Only
//  the path / availability statics remain in use; they're kept under
//  the `VideoCache` namespace because the call sites already use that
//  prefix throughout the codebase.
//

import Foundation
import AVFoundation

final class VideoCache {

    // MARK: - Path Properties

    /// Returns the unified support path
    static var appSupportDirectory: String? {
        return Cache.supportPath
    }

    /// Returns the unified cache path
    static var cacheDirectory: String? {
        return Cache.path
    }

    // MARK: - Video Availability

    // Is a video cached
    static func isAvailableOffline(video: AerialVideo) -> Bool {
        let fileManager = FileManager.default

        if video.url.absoluteString.starts(with: "file") {
            return fileManager.fileExists(atPath: video.url.path)
        } else {
            if video.source.isCachable {
                guard let videoCachePath = cachePath(forVideo: video) else {
                    errorLog("Couldn't get video cache path!")
                    return false
                }

                if fileManager.fileExists(atPath: videoCachePath) {
                    do {
                        let fileUrl = Foundation.URL(fileURLWithPath: videoCachePath)
                        let resourceValues = try fileUrl.resourceValues(forKeys: [.fileSizeKey])
                        let fileSize = resourceValues.fileSize!

                        // Make sure the file is big enough to be a video and not some network failure
                        if fileSize > 500000 {
                            return true
                        }

                    } catch {
                        errorLog("File check throw")
                    }
                }

                return false
            } else {
                let path = sourcePathFor(video)
                // "Not downloaded yet" is the normal case for non-cachable
                // sources — return false silently instead of throwing
                // NSCocoaErrorDomain 260 from `resourceValues` below.
                guard fileManager.fileExists(atPath: path) else { return false }
                do {
                    let fileUrl = Foundation.URL(fileURLWithPath: path)
                    let resourceValues = try fileUrl.resourceValues(forKeys: [.fileSizeKey])
                    let fileSize = resourceValues.fileSize!

                    // Make sure the file is big enough to be a video and not some network failure
                    if fileSize > 500000 {
                        return true
                    }

                } catch {
                    errorLog("File check throw: \(error.localizedDescription)")
                }
                return false
            }
        }
    }

    static func cachePath(forVideo video: AerialVideo) -> String? {
        if video.url.absoluteString.starts(with: "file") {
            return video.url.path
        }

        let vurl = video.url
        let filename = vurl.lastPathComponent
        return cachePath(forFilename: filename)
    }

    static func cachePath(forFilename filename: String) -> String? {
        guard let cacheDirectory = VideoCache.cacheDirectory, let appSupportDirectory = VideoCache.appSupportDirectory else {
            return nil
        }

        // Let's compute both
        let appSupportPath = appSupportDirectory as NSString
        let appSupportVideoPath = appSupportPath.appendingPathComponent(filename)

        let cacheDirectoryPath = cacheDirectory as NSString
        let cacheVideoPath = cacheDirectoryPath.appendingPathComponent(filename)

        // If the file exists in either dir, returns that
        if FileManager.default.fileExists(atPath: appSupportVideoPath as String) {
            return appSupportVideoPath
        } else if FileManager.default.fileExists(atPath: cacheVideoPath as String) {
            return cacheVideoPath
        } else {
            // File doesn't have to exist, this is also used to compute the save location
            return cacheVideoPath
        }
    }

    static func sourcePathFor(_ video: AerialVideo) -> String {
        if video.url.isFileURL {
            return video.url.path
        } else {
            return Cache.supportPath.appending("/Sources/" + video.source.name + "/" + video.url.lastPathComponent)
        }
    }
}
