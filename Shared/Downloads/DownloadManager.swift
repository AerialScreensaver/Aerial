//
//  DownloadManager.swift
//  Aerial
//
//  Created by Guillaume Louel on 03/10/2018.
//  Copyright © 2018 John Coates. All rights reserved.

import Cocoa

/// Manager of asynchronous download `Operation` objects

final class DownloadManager: NSObject {

    /// Dictionary of operations, keyed by the `taskIdentifier` of the `URLSessionTask`

    fileprivate var operations = [Int: DownloadOperation]()

    /// Serial OperationQueue for downloads

    private let queue: OperationQueue = {
        let operationQueue = OperationQueue()
        operationQueue.name = "download"
        operationQueue.maxConcurrentOperationCount = 3
        return operationQueue
    }()

    /// Delegate-based `URLSession` for DownloadManager

    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Add download
    ///
    /// - parameter URL:  The URL of the file to be downloaded
    ///          folder:  The name of the subfolder where the file will be stored
    ///
    /// - returns:        The DownloadOperation of the operation that was queued

    @discardableResult
    func queueDownload(_ url: URL, folder: String) -> DownloadOperation {
        let operation = DownloadOperation(session: session, url: url, folder: folder)
        operations[operation.task.taskIdentifier] = operation
        queue.addOperation(operation)
        return operation
    }

}

// MARK: URLSessionDownloadDelegate methods

extension DownloadManager: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        operations[downloadTask.taskIdentifier]?.urlSession(session,
                                                            downloadTask: downloadTask,
                                                            didFinishDownloadingTo: location)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        operations[downloadTask.taskIdentifier]?.urlSession(session,
                                                            downloadTask: downloadTask,
                                                            didWriteData: bytesWritten,
                                                            totalBytesWritten: totalBytesWritten,
                                                            totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }
}

// MARK: URLSessionTaskDelegate methods

extension DownloadManager: URLSessionTaskDelegate {

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = task.taskIdentifier
        operations[key]?.urlSession(session, task: task, didCompleteWithError: error)
        operations.removeValue(forKey: key)
    }

}

/// Asynchronous Operation subclass for downloading

final class DownloadOperation: AsynchronousOperation, @unchecked Sendable {
    let task: URLSessionTask
    let folder: String

    init(session: URLSession, url: URL, folder: String) {
        self.folder = folder
        task = session.downloadTask(with: url)
        super.init()
    }

    override func cancel() {
        task.cancel()
        super.cancel()
    }

    override func main() {
        task.resume()
    }
}

extension DownloadOperation {
    /// Resolve the on-disk destination for a download's `folder` (a
    /// source NAME, or empty for base-directory manifests). Sources may
    /// live under the default root OR the external Expansions root —
    /// the source's `folderPath` knows which (installs append to
    /// `SourceList.list` before queueing, so the lookup always hits).
    static func destinationDirectory(for folder: String) -> String {
        if folder.isEmpty { return Cache.supportPath }
        if let source = SourceList.list.first(where: { $0.name == folder }) {
            return source.folderPath
        }
        return Cache.defaultSourcesRoot + "/" + folder
    }
}

// MARK: NSURLSessionDownloadDelegate methods
//       Customized for our usage
extension DownloadOperation: URLSessionDownloadDelegate {
    // This is where we save the file to its location
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            // We may need to create our destination
            // Use the source's folder for source downloads, root for empty folder (manifests)
            let destinationDirectory = DownloadOperation.destinationDirectory(for: folder)
            FileHelpers.createDirectory(atPath: destinationDirectory)

            let manager = FileManager.default
            let supportURL = URL(fileURLWithPath: destinationDirectory)

            let fileName = downloadTask.originalRequest?.url?.lastPathComponent ?? "unknown"
            debugLog("Caching \(fileName) at \(folder)")

            // The file may exist, remove it
            try? manager.removeItem(at: supportURL.appendingPathComponent(fileName))

            // Finally move the file
            try manager.moveItem(at: location, to: supportURL.appendingPathComponent(fileName))
        } catch {
            errorLog("\(error)")
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        // print("\(downloadTask.originalRequest!.url!.absoluteString) \(progress)")
    }
}

// MARK: URLSessionTaskDelegate methods

extension DownloadOperation: URLSessionTaskDelegate {

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { finish() }

        if let error = error {
            errorLog("\(error)")
            return
        }

        // Use the source's folder for source downloads, root for empty folder (manifests)
        let destinationDirectory = DownloadOperation.destinationDirectory(for: folder)

        // Apple's feeds (macOS / tvOS `resources-*.tar`) come as tars:
        // install them through the staged extraction so a bad download
        // never clobbers a working entries.json, and so the tar name —
        // not the source name — decides what gets extracted (a feed bump
        // is a URL change in SourceList, nothing here). Community
        // entries.json / manifest.json files are used in place.
        let fileName = task.originalRequest?.url?.lastPathComponent ?? ""
        if fileName.hasSuffix(".tar") {
            if FileHelpers.installFeedArchive(tar: destinationDirectory + "/" + fileName, into: destinationDirectory) {
                PoiStringProvider.sharedInstance.invalidate()
            }
        }

        debugLog("Finished downloading \(task.originalRequest!.url!.absoluteString)")
    }
}
