//
//  VideoDownloadResume.swift
//  Aerial
//
//  Persistent per-video download resume state. Lets `VideoDownload`
//  pick up an interrupted multi-GB transfer from where it stopped
//  instead of re-downloading from byte 0.
//
//  The blob bundles three things keyed by video ID:
//    - `url`        — the URL the resume data was captured for. If the
//                     URL changes (user picks a different per-video
//                     format, or manifest rotates) we discard the blob.
//    - `savedAt`    — wall-clock at capture. Resume data from CDNs
//                     using signed URLs (e.g. GitHub Releases →
//                     objects.githubusercontent.com JWT) goes stale on
//                     a TTL; a 30 min window is the cheap insurance.
//    - `resumeData` — the opaque blob URLSession needs to construct
//                     `downloadTask(withResumeData:)`.
//
//  Stored at `/Users/Shared/Aerial/Cache/.resume/<videoId>.plist`.
//

import Foundation

struct VideoDownloadResume {
    /// Maximum age of a resume blob before we treat it as expired. Keeps
    /// signed-URL TTLs (typical CDN: 5–60 min) from biting us.
    static let maxAge: TimeInterval = 30 * 60

    /// Wraps the persisted shape on disk.
    private struct Blob: Codable {
        let url: String
        let savedAt: Date
        let resumeData: Data
    }

    private static var directory: URL {
        URL(fileURLWithPath: Cache.supportPath)
            .appendingPathComponent("Cache")
            .appendingPathComponent(".resume")
    }

    private static func fileURL(for videoId: String) -> URL {
        directory.appendingPathComponent("\(videoId).plist")
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }

    /// Persist `resumeData` for `videoId` alongside the URL it was
    /// captured for. Best-effort — failures are logged and the next
    /// attempt will simply start from byte 0.
    static func save(videoId: String, url: String, resumeData: Data) {
        ensureDirectory()
        let blob = Blob(url: url, savedAt: Date(), resumeData: resumeData)
        do {
            let encoded = try PropertyListEncoder().encode(blob)
            try encoded.write(to: fileURL(for: videoId), options: .atomic)
        } catch {
            errorLog("VideoDownloadResume: save failed for \(videoId): \(error.localizedDescription)")
        }
    }

    /// Load resume data for `videoId` *only if* the persisted URL still
    /// matches `expectedURL` and the blob is younger than `maxAge`.
    /// Otherwise (or on any read error) returns nil and the blob on
    /// disk is removed so the next attempt starts clean.
    static func load(videoId: String, expectedURL: String) -> Data? {
        let url = fileURL(for: videoId)
        guard let data = try? Data(contentsOf: url),
              let blob = try? PropertyListDecoder().decode(Blob.self, from: data) else {
            return nil
        }
        if blob.url != expectedURL {
            debugLog("VideoDownloadResume: discarding blob for \(videoId) — URL changed")
            clear(videoId: videoId)
            return nil
        }
        let age = Date().timeIntervalSince(blob.savedAt)
        if age > maxAge {
            debugLog("VideoDownloadResume: discarding blob for \(videoId) — \(Int(age))s old (>\(Int(maxAge))s)")
            clear(videoId: videoId)
            return nil
        }
        return blob.resumeData
    }

    /// Remove the persisted blob for `videoId`. No-op if absent.
    static func clear(videoId: String) {
        try? FileManager.default.removeItem(at: fileURL(for: videoId))
    }
}
