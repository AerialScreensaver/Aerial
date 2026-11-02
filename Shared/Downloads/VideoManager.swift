//
//  VideoManager.swift
//  Aerial
//
//  Created by Guillaume Louel on 08/10/2018.
//  Copyright © 2018 John Coates. All rights reserved.
//

import Foundation
typealias VideoManagerCallback = (Int, Int) -> Void
typealias VideoProgressCallback = (Int, Int, Double) -> Void
/// Per-video completion callback: (videoId, success, errorMessage).
/// Lets subscribers react to specific failures (e.g. MD5 mismatch
/// re-queue) that the queue-progress `VideoManagerCallback` doesn't
/// expose.
typealias VideoFinishedCallback = (String, Bool, String?) -> Void

final class VideoManager: NSObject {
    static let sharedInstance = VideoManager()
    var managerCallbacks = [VideoManagerCallback]()
    var progressCallbacks = [VideoProgressCallback]()
    var finishedCallbacks = [VideoFinishedCallback]()

    /// Queue bookkeeping is touched from DownloadCoordinator's work queue
    /// (queueDownload), main (finishedDownload via the download delegate) and
    /// the OperationQueue thread (activeDownloadId). One lock covers it all.
    private let stateLock = NSLock()

    /// List of queued videos, by video.id
    private var queuedVideos = [String]()

    /// The video.id currently being downloaded (set when operation starts)
    private var activeDownloadStorage: String?
    var activeDownloadId: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return activeDownloadStorage
    }
    fileprivate func markActive(_ id: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        activeDownloadStorage = id
    }

    /// Public accessor for the queued video IDs
    var queuedVideoIds: [String] {
        stateLock.lock(); defer { stateLock.unlock() }
        return queuedVideos
    }

    /// Dictionary of operations, keyed by the video.id
    private var operations = [String: VideoDownloadOperation]()

    /// Number of videos that were queued
    private var totalQueued = 0
    var stopAll = false

    // var downloadItems: [VideoDownloadItem]
    /// Serial OperationQueue for downloads

    private let queue: OperationQueue

    /// `queue` is injectable so tests can hand in a suspended queue and
    /// inspect what got enqueued without touching the network.
    init(queue: OperationQueue? = nil) {
        if let queue {
            self.queue = queue
        } else {
            let downloads = OperationQueue()
            downloads.name = "videodownload"
            downloads.maxConcurrentOperationCount = 1
            self.queue = downloads
        }
        super.init()
    }

    func addCallback(_ callback:@escaping VideoManagerCallback) {
        managerCallbacks.append(callback)
    }

    func addProgressCallback(_ callback:@escaping VideoProgressCallback) {
        progressCallbacks.append(callback)
    }

    func addFinishedCallback(_ callback: @escaping VideoFinishedCallback) {
        finishedCallbacks.append(callback)
    }

    @discardableResult
    func queueDownload(_ video: AerialVideo) -> VideoDownloadOperation {
        if stopAll {
            stopAll = false
        }

        // Same video queued twice (card + inspector, manual + coordinator
        // sweep) used to start two downloads racing for one cache file.
        // Hand back the live operation instead.
        let operation: VideoDownloadOperation
        let completed: Int
        let total: Int
        stateLock.lock()
        if let existing = operations[video.id], !existing.isCancelled, !existing.isFinished {
            stateLock.unlock()
            debugLog("VideoManager: \(video.name) already queued — reusing the live download")
            return existing
        }
        operation = VideoDownloadOperation(video: video, delegate: self)
        operations[video.id] = operation
        queuedVideos.append(video.id)       // Our Internal List of queued videos
        totalQueued += 1                    // Increment our count
        completed = totalQueued - queuedVideos.count
        total = totalQueued
        stateLock.unlock()
        queue.addOperation(operation)

        DispatchQueue.main.async {
            // Callback the callbacks
            for callback in self.managerCallbacks {
                callback(completed, total)
            }
        }
        return operation
    }

    /// Cancel one queued or in-flight download, leaving the rest of the
    /// queue alone. No-op when nothing live is tracked for `id`.
    func cancelDownload(id: String) {
        stateLock.lock()
        let operation = operations[id]
        stateLock.unlock()
        guard let operation, !operation.isCancelled, !operation.isFinished else { return }
        operation.cancel()
    }

    /// A rendition change invalidates every queued and in-flight request:
    /// their bytes belong to the old format and must never land under the
    /// new format's filename (`VideoDownload` double-checks on completion;
    /// this just stops the wasted transfer early). Cached files are
    /// untouched — that's the caller's `Cache.clearCache()` decision.
    func cancelDownloadsForFormatChange() {
        let ids = queuedVideoIds
        guard !ids.isEmpty else { return }
        infoLog("VideoManager: video format changed — cancelling \(ids.count) queued download(s)")
        for id in ids {
            cancelDownload(id: id)
        }
    }

    // Callbacks for Items
    func finishedDownload(id: String, success: Bool, errorMessage: String? = nil) {
        stateLock.lock()
        // Clear active download tracking
        if activeDownloadStorage == id {
            activeDownloadStorage = nil
        }

        // Manage our queuedVideo index
        if let index = queuedVideos.firstIndex(of: id) {
            queuedVideos.remove(at: index)
        }

        // Snapshot values BEFORE potential reset so callbacks see correct counts
        let completed = totalQueued - queuedVideos.count
        let total = totalQueued

        if queuedVideos.isEmpty {
            totalQueued = 0
        }
        stateLock.unlock()

        debugLog("VideoManager: download finished id=\(id) success=\(success) (\(completed)/\(total))")

        DispatchQueue.main.async {
            for callback in self.finishedCallbacks {
                callback(id, success, errorMessage)
            }
            for callback in self.managerCallbacks {
                callback(completed, total)
            }
        }
    }

    func updateProgress(id: String, progress: Double) {
        stateLock.lock()
        let completed = totalQueued - queuedVideos.count
        let total = totalQueued
        stateLock.unlock()
        DispatchQueue.main.async {
            // Callback the callbacks
            for callback in self.progressCallbacks {
                callback(completed, total, progress)
            }
        }
    }

}

final class VideoDownloadOperation: AsynchronousOperation, @unchecked Sendable {
    var video: AerialVideo
    var download: VideoDownload?
    /// The manager that queued us — injected rather than read off the
    /// singleton so a test-owned `VideoManager(queue:)` sees its own
    /// callbacks.
    private weak var manager: VideoManager?

    init(video: AerialVideo, delegate: VideoManager) {
        debugLog("Video queued \(video.name)")
        self.video = video
        self.manager = delegate
    }

    override func main() {
        guard !isCancelled, let videoManager = manager else {
            finish()
            return
        }
        if videoManager.stopAll {
            finish()
            return
        }

        debugLog("Starting download for \(video.name)")
        videoManager.markActive(video.id)
        DispatchQueue.main.async {
            // Cancelled between the queue starting us and this hop:
            // `cancel()` already reported the failure, don't start.
            guard !self.isCancelled else { return }
            self.download = VideoDownload(video: self.video, delegate: self)
            self.download!.startDownload()
        }
    }

    override func cancel() {
        defer { finish() }

        if let download = self.download {
            download.cancel()
        } else {
            manager?.finishedDownload(id: self.video.id, success: false)
        }
        self.download = nil
        super.cancel()
    }
}

extension VideoDownloadOperation: VideoDownloadDelegate {
    func videoDownload(_ videoDownload: VideoDownload,
                       finished success: Bool, errorMessage: String?) {
        debugLog("VideoDownloadOperation: \(success ? "completed" : "failed") \(videoDownload.video.name)")
        defer { finish() }

        guard let videoManager = manager else { return }
        if success {
            // Call up to clean the view
            videoManager.finishedDownload(id: videoDownload.video.id, success: true)
        } else {
            if let msg = errorMessage {
                errorLog(msg)
            }

            videoManager.finishedDownload(id: videoDownload.video.id, success: false,
                                          errorMessage: errorMessage)
        }
    }

    func videoDownload(_ videoDownload: VideoDownload, receivedBytes: Int, progress: Float) {
        // Call up to update the view
        guard let videoManager = manager else { return }
        videoManager.updateProgress(id: videoDownload.video.id, progress: Double(progress))
    }
}
