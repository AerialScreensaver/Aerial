//
//  DownloadTracker.swift
//  Aerial Companion
//
//  Lightweight ObservableObject bridging VideoManager download callbacks to SwiftUI.
//  Publishes download state for playlist badges and menubar dot indicator.
//

import Foundation
import Combine

enum VideoDownloadState {
    case none
    case queued
    case downloading(progress: Double)
}

@MainActor
class DownloadTracker: ObservableObject {

    static let shared = DownloadTracker()

    // MARK: - Published State

    @Published var isDownloading: Bool = false
    @Published var activeProgress: Double = 0.0
    @Published var downloadingVideoIds: Set<String> = []

    // MARK: - Notifications

    static let isDownloadingDidChangeNotification = Notification.Name("com.glouel.aerial.isDownloadingDidChange")

    // MARK: - Init

    private init() {
        // Manager callback: fires when a download finishes (completed/total counts)
        VideoManager.sharedInstance.addCallback { [weak self] completed, total in
            DispatchQueue.main.async {
                self?.handleManagerUpdate(completed: completed, total: total)
            }
        }

        // Progress callback: fires during active download with fractional progress
        VideoManager.sharedInstance.addProgressCallback { [weak self] completed, total, progress in
            DispatchQueue.main.async {
                self?.handleProgressUpdate(completed: completed, total: total, progress: progress)
            }
        }

        // Observe DownloadCoordinator start notification to refresh queued IDs
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onDownloadDidStart),
            name: DownloadCoordinator.downloadDidStartNotification,
            object: nil
        )

        // Observe DownloadCoordinator completion to clear state
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onDownloadDidComplete),
            name: DownloadCoordinator.downloadDidCompleteNotification,
            object: nil
        )
    }

    // MARK: - Public API

    func state(for videoId: String) -> VideoDownloadState {
        let vm = VideoManager.sharedInstance
        if vm.activeDownloadId == videoId {
            return .downloading(progress: activeProgress)
        }
        if vm.queuedVideoIds.contains(videoId) {
            return .queued
        }
        return .none
    }

    /// Queue a manual download for the given video ID.
    func queueDownload(videoId: String) {
        guard let video = VideoList.instance.videos.first(where: { $0.id == videoId }) else { return }
        debugLog("DownloadTracker: manual download queued for \(video.secondaryName) (\(videoId))")
        VideoManager.sharedInstance.queueDownload(video)
        NotificationCenter.default.post(
            name: DownloadCoordinator.downloadDidStartNotification, object: nil
        )
    }

    // MARK: - Internal

    private func handleManagerUpdate(completed: Int, total: Int) {
        refreshDownloadingIds()
    }

    private func handleProgressUpdate(completed: Int, total: Int, progress: Double) {
        self.activeProgress = progress
        refreshDownloadingIds()
    }

    @objc private func onDownloadDidStart() {
        refreshDownloadingIds()
    }

    @objc private func onDownloadDidComplete() {
        refreshDownloadingIds()
    }

    private func refreshDownloadingIds() {
        let ids = Set(VideoManager.sharedInstance.queuedVideoIds)
        if ids != downloadingVideoIds {
            downloadingVideoIds = ids
        }

        let nowDownloading = !ids.isEmpty
        if nowDownloading != isDownloading {
            isDownloading = nowDownloading
            NotificationCenter.default.post(name: Self.isDownloadingDidChangeNotification, object: nowDownloading)
        }

        // Reset progress when nothing is downloading
        if !nowDownloading {
            activeProgress = 0.0
        }
    }
}
