//
//  VideoDownload.swift
//  Aerial
//
//  Created by John Coates on 10/31/15.
//  Copyright © 2015 John Coates. All rights reserved.
//

import Foundation

protocol VideoDownloadDelegate: NSObjectProtocol {
    func videoDownload(_ videoDownload: VideoDownload,
                       finished success: Bool, errorMessage: String?)
    // bytes received for bytes/second count
    func videoDownload(_ videoDownload: VideoDownload,
                       receivedBytes: Int, progress: Float)
}

final class VideoDownload: NSObject, URLSessionDownloadDelegate {
    /// Error message used when an MD5 verification fails. Upstream
    /// (`DownloadCoordinator`) matches against this exact string to
    /// decide "should I re-queue this video?".
    static let md5MismatchErrorMessage = "MD5 mismatch — file removed for re-download"

    /// Error message used when the server returned a non-2xx response
    /// whose body suggests a stale signed URL (GitHub's 618/jwt:expired
    /// or any `expired`/`jwt`-flavoured 4xx). The resume blob is bad,
    /// the URL needs to be re-fetched fresh — `DownloadCoordinator`
    /// burns one retry against the original `video.url`.
    static let staleURLErrorMessage = "Stale URL — re-fetch needed"

    /// Error message used when the server returned any other non-2xx
    /// response. Caught by the same gate as stale-URL but doesn't
    /// imply a re-fetch will help, so the upstream layer treats it as
    /// a normal failure.
    static let httpErrorMessagePrefix = "HTTP error: "

    weak var delegate: VideoDownloadDelegate?
    let video: AerialVideo
    private var downloadTask: URLSessionDownloadTask?
    private var hasNotifiedCompletion = false

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }()

    init(video: AerialVideo, delegate: VideoDownloadDelegate) {
        self.video = video
        self.delegate = delegate
    }

    func startDownload() {
        let urlString = video.url.absoluteString
        if let resumeData = VideoDownloadResume.load(videoId: video.id, expectedURL: urlString) {
            debugLog("Resuming URLSession download for \(video.name) (\(resumeData.count) bytes of resume state)")
            downloadTask = session.downloadTask(withResumeData: resumeData)
        } else {
            debugLog("Starting URLSession download for \(video.name)")
            downloadTask = session.downloadTask(with: video.url)
        }
        downloadTask?.resume()
    }

    func cancel() {
        hasNotifiedCompletion = true
        downloadTask?.cancel()
        session.invalidateAndCancel()
        infoLog("Video download cancelled")
        delegate?.videoDownload(self, finished: false, errorMessage: nil)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        hasNotifiedCompletion = true

        // URLSessionDownloadTask reports HTTP 4xx/5xx as "success" — the
        // body gets saved to `location` regardless. Catch that before
        // we move bytes into the cache. On stale-URL signals (GitHub's
        // 618/jwt:expired and similar) the resume blob is dead too, so
        // we wipe it and tag the failure for `DownloadCoordinator` to
        // burn one re-fetch retry against the original URL.
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            let bodySnippet = Self.peekBody(at: location)
            let isStale = response.statusCode >= 400 &&
                          response.statusCode < 500 &&
                          (bodySnippet.range(of: "jwt", options: .caseInsensitive) != nil
                           || bodySnippet.contains("618")
                           || bodySnippet.range(of: "expired", options: .caseInsensitive) != nil)
            if isStale {
                errorLog("Download failed for \(video.name): HTTP \(response.statusCode), stale signed URL — \(bodySnippet)")
                VideoDownloadResume.clear(videoId: video.id)
                delegate?.videoDownload(self, finished: false,
                                        errorMessage: VideoDownload.staleURLErrorMessage)
            } else {
                errorLog("Download failed for \(video.name): HTTP \(response.statusCode) — \(bodySnippet)")
                VideoDownloadResume.clear(videoId: video.id)
                delegate?.videoDownload(self, finished: false,
                                        errorMessage: VideoDownload.httpErrorMessagePrefix + "\(response.statusCode)")
            }
            try? FileManager.default.removeItem(at: location)
            session.invalidateAndCancel()
            return
        }

        let tentativeCachePath: String?
        if video.source.isCachable {
            tentativeCachePath = VideoCache.cachePath(forVideo: video)
        } else {
            tentativeCachePath = VideoCache.sourcePathFor(video)
        }

        guard let videoCachePath = tentativeCachePath else {
            errorLog("Couldn't save video — no cache path for \(video.name)")
            delegate?.videoDownload(self, finished: false, errorMessage: "Couldn't get cache path")
            session.invalidateAndCancel()
            return
        }

        let destinationURL = URL(fileURLWithPath: videoCachePath)

        do {
            // Remove any existing file at the destination
            let fm = FileManager.default
            if fm.fileExists(atPath: videoCachePath) {
                try fm.removeItem(at: destinationURL)
            }

            // Ensure the parent directory exists
            let parentDir = destinationURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            try fm.moveItem(at: location, to: destinationURL)
        } catch {
            errorLog("Couldn't move downloaded file to cache: \(error)")
            delegate?.videoDownload(self, finished: false, errorMessage: "Couldn't write to cache file!")
            session.invalidateAndCancel()
            return
        }

        debugLog("Download complete: \(video.name)")
        // The download is done — free the session before we kick off
        // any (possibly seconds-long) MD5 hashing.
        session.invalidateAndCancel()

        // Verify against the manifest's published MD5 for the format we
        // just fetched. Skip when no checksum is published — same
        // behaviour as before this field existed.
        let format = video.effectiveFormat()
        if let expected = video.urlMD5s[format], !expected.isEmpty {
            // Hash on a utility queue so a multi-GB digest doesn't
            // block main; come back to main for the delegate notify
            // (this delegate's contract is "called on main").
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                let actual = MD5Verifier.md5Hex(of: destinationURL)
                DispatchQueue.main.async {
                    if actual?.lowercased() != expected.lowercased() {
                        errorLog("MD5 mismatch for \(self.video.name) [\(format)] — expected \(expected), got \(actual ?? "nil")")
                        try? FileManager.default.removeItem(at: destinationURL)
                        // The resumed bytes are confirmed bad — drop the
                        // blob so the next attempt starts from byte 0.
                        VideoDownloadResume.clear(videoId: self.video.id)
                        self.delegate?.videoDownload(self, finished: false,
                                                     errorMessage: VideoDownload.md5MismatchErrorMessage)
                    } else {
                        debugLog("MD5 verified for \(self.video.name) [\(format)]")
                        VideoDownloadResume.clear(videoId: self.video.id)
                        self.delegate?.videoDownload(self, finished: true, errorMessage: nil)
                    }
                }
            }
        } else {
            VideoDownloadResume.clear(videoId: video.id)
            delegate?.videoDownload(self, finished: true, errorMessage: nil)
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
        delegate?.videoDownload(self, receivedBytes: Int(bytesWritten), progress: progress)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error, !hasNotifiedCompletion {
            // Don't log cancellation as an error
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                debugLog("Download cancelled for \(video.name)")
            } else {
                errorLog("Download failed for \(video.name): \(error.localizedDescription)")
                // Capture resume data so the next attempt picks up
                // where we left off instead of restarting from byte 0.
                // URLSession includes it in the error's userInfo on
                // recoverable network failures.
                if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    VideoDownloadResume.save(videoId: video.id,
                                             url: video.url.absoluteString,
                                             resumeData: resumeData)
                    debugLog("Saved resume blob (\(resumeData.count) bytes) for \(video.name)")
                }
            }
            delegate?.videoDownload(self, finished: false, errorMessage: error.localizedDescription)
        }
        session.invalidateAndCancel()
    }

    /// Reads up to a few KB off the temp file URLSession leaves behind
    /// so we can include a snippet in error logs (and pattern-match for
    /// `jwt`/`618`/`expired`). Always best-effort — unreadable / huge
    /// payloads return an empty string so we don't OOM trying to log a
    /// truncated video.
    private static func peekBody(at url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 2048)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
