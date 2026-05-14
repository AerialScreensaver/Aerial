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

    /// List of queued videos, by video.id
    private var queuedVideos = [String]()

    /// The video.id currently being downloaded (set when operation starts)
    fileprivate(set) var activeDownloadId: String?

    /// Public accessor for the queued video IDs
    var queuedVideoIds: [String] { queuedVideos }

    /// Dictionary of operations, keyed by the video.id
    fileprivate var operations = [String: VideoDownloadOperation]()

    /// Number of videos that were queued
    private var totalQueued = 0
    var stopAll = false

    // var downloadItems: [VideoDownloadItem]
    /// Serial OperationQueue for downloads

    private let queue: OperationQueue = {
        // swiftlint:disable:next identifier_name
        let _queue = OperationQueue()
        _queue.name = "videodownload"
        _queue.maxConcurrentOperationCount = 1

        return _queue
    }()

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

        let operation = VideoDownloadOperation(video: video, delegate: self)
        operations[video.id] = operation
        queue.addOperation(operation)

        queuedVideos.append(video.id)       // Our Internal List of queued videos
        totalQueued += 1                    // Increment our count

        DispatchQueue.main.async {
            // Callback the callbacks
            for callback in self.managerCallbacks {
                callback(self.totalQueued-self.queuedVideos.count, self.totalQueued)
            }
        }
        return operation
    }

    // Callbacks for Items
    func finishedDownload(id: String, success: Bool, errorMessage: String? = nil) {
        // Clear active download tracking
        if activeDownloadId == id {
            activeDownloadId = nil
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
        DispatchQueue.main.async {
            // Callback the callbacks
            for callback in self.progressCallbacks {
                callback(self.totalQueued-self.queuedVideos.count, self.totalQueued, progress)
            }
        }
    }

}

final class VideoDownloadOperation: AsynchronousOperation {
    var video: AerialVideo
    var download: VideoDownload?

    init(video: AerialVideo, delegate: VideoManager) {
        debugLog("Video queued \(video.name)")
        self.video = video
    }

    override func main() {
        let videoManager = VideoManager.sharedInstance
        if videoManager.stopAll {
            finish()
            return
        }

        debugLog("Starting download for \(video.name)")
        videoManager.activeDownloadId = video.id
        DispatchQueue.main.async {
            self.download = VideoDownload(video: self.video, delegate: self)
            self.download!.startDownload()
        }
    }

    override func cancel() {
        defer { finish() }
        let videoManager = VideoManager.sharedInstance

        if let _ = self.download {
            self.download!.cancel()
        } else {
            videoManager.finishedDownload(id: self.video.id, success: false)
        }
        self.download = nil
        super.cancel()
        // finish()
    }
}

extension VideoDownloadOperation: VideoDownloadDelegate {
    func videoDownload(_ videoDownload: VideoDownload,
                       finished success: Bool, errorMessage: String?) {
        debugLog("VideoDownloadOperation: \(success ? "completed" : "failed") \(videoDownload.video.name)")
        defer { finish() }

        let videoManager = VideoManager.sharedInstance
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
        let videoManager = VideoManager.sharedInstance
        videoManager.updateProgress(id: videoDownload.video.id, progress: Double(progress))
    }
}
