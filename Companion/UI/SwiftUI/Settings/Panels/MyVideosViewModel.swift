//
//  MyVideosViewModel.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 20/01/2026.
//

import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Video Status

@available(macOS 13.0, *)
enum LocalVideoStatus: Equatable {
    case valid
    case tooSmall           // < 500KB
    case unsupportedFormat  // not .mp4/.mov
    case unreadable         // can't open file

    var description: String {
        switch self {
        case .valid:
            return "Ready to play"
        case .tooSmall:
            return "File too small (< 500KB)"
        case .unsupportedFormat:
            return "Unsupported format"
        case .unreadable:
            return "Cannot read file"
        }
    }

    var isPlayable: Bool {
        self == .valid
    }
}

// MARK: - Local Video Info

@available(macOS 13.0, *)
struct LocalVideoInfo: Identifiable, Equatable {
    let id: String
    let filename: String
    let path: String
    let fileSize: Int64
    let status: LocalVideoStatus
    var duration: TimeInterval?
    var thumbnail: NSImage?

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    var formattedDuration: String? {
        guard let duration = duration else { return nil }
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    var fileExtension: String {
        URL(fileURLWithPath: path).pathExtension.uppercased()
    }

    static func == (lhs: LocalVideoInfo, rhs: LocalVideoInfo) -> Bool {
        lhs.id == rhs.id &&
        lhs.filename == rhs.filename &&
        lhs.path == rhs.path &&
        lhs.fileSize == rhs.fileSize &&
        lhs.status == rhs.status &&
        lhs.duration == rhs.duration
    }
}

// MARK: - My Videos View Model

@available(macOS 13.0, *)
@MainActor
class MyVideosViewModel: ObservableObject {
    @Published var videos: [LocalVideoInfo] = []
    @Published var isLoading: Bool = false
    @Published var isImporting: Bool = false
    @Published var importProgress: String = ""

    private let folderPath = "/Users/Shared/Aerial/My Videos"
    private let supportedExtensions = ["mp4", "mov"]
    private let minimumFileSize: Int64 = 500_000  // 500KB

    // MARK: - Public Methods

    func scanFolder() {
        isLoading = true

        Task {
            let scannedVideos = await performScan()
            self.videos = scannedVideos
            self.isLoading = false

            // Load thumbnails and durations asynchronously
            for video in scannedVideos where video.status == .valid {
                loadMetadata(for: video)
            }
        }
    }

    func importVideos(urls: [URL]) {
        guard !urls.isEmpty else { return }

        isImporting = true
        importProgress = "Importing \(urls.count) file(s)..."

        Task {
            var importedCount = 0

            for url in urls {
                let filename = url.lastPathComponent
                let destinationURL = URL(fileURLWithPath: folderPath).appendingPathComponent(filename)

                // Handle duplicate filenames
                let finalDestination = uniqueDestination(for: destinationURL)

                do {
                    try FileManager.default.copyItem(at: url, to: finalDestination)
                    importedCount += 1
                    importProgress = "Imported \(importedCount) of \(urls.count)..."
                } catch {
                    CompanionLogging.errorLog("Failed to import \(filename): \(error.localizedDescription)")
                }
            }

            // Refresh the source list so Aerial picks up new videos
            SourceList.ensureDefaultLocalSource()

            // Rescan the folder
            scanFolder()

            isImporting = false
            importProgress = ""
        }
    }

    func deleteVideo(_ video: LocalVideoInfo) {
        let url = URL(fileURLWithPath: video.path)

        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)

            // Remove from list
            videos.removeAll { $0.id == video.id }

            // Refresh the source list
            SourceList.ensureDefaultLocalSource()
        } catch {
            CompanionLogging.errorLog("Failed to delete \(video.filename): \(error.localizedDescription)")
        }
    }

    func openInFinder() {
        let url = URL(fileURLWithPath: folderPath)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    func revealInFinder(_ video: LocalVideoInfo) {
        NSWorkspace.shared.selectFile(video.path, inFileViewerRootedAtPath: folderPath)
    }

    // MARK: - Private Methods

    private func performScan() async -> [LocalVideoInfo] {
        let url = URL(fileURLWithPath: folderPath)

        guard FileManager.default.fileExists(atPath: folderPath) else {
            CompanionLogging.errorLog("My Videos folder doesn't exist: \(folderPath)")
            return []
        }

        var results: [LocalVideoInfo] = []

        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )

            for fileUrl in urls {
                let resourceValues = try? fileUrl.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                let fileSize = Int64(resourceValues?.fileSize ?? 0)
                let isRegularFile = resourceValues?.isRegularFile ?? false
                let isSymbolicLink = resourceValues?.isSymbolicLink ?? false

                // Skip directories
                guard isRegularFile || isSymbolicLink else { continue }

                let ext = fileUrl.pathExtension.lowercased()
                let status: LocalVideoStatus

                if !supportedExtensions.contains(ext) {
                    status = .unsupportedFormat
                } else if fileSize < minimumFileSize && !isSymbolicLink {
                    status = .tooSmall
                } else {
                    status = .valid
                }

                let video = LocalVideoInfo(
                    id: UUID().uuidString,
                    filename: fileUrl.lastPathComponent,
                    path: fileUrl.path,
                    fileSize: fileSize,
                    status: status,
                    duration: nil,
                    thumbnail: nil
                )

                results.append(video)
            }
        } catch {
            CompanionLogging.errorLog("Failed to scan My Videos folder: \(error.localizedDescription)")
        }

        // Sort: valid videos first, then by filename
        return results.sorted { lhs, rhs in
            if lhs.status.isPlayable != rhs.status.isPlayable {
                return lhs.status.isPlayable
            }
            return lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
        }
    }

    private func loadMetadata(for video: LocalVideoInfo) {
        Task.detached { [weak self] in
            let url = URL(fileURLWithPath: video.path)
            let asset = AVAsset(url: url)

            // Load duration
            let duration: TimeInterval?
            do {
                let durationValue = try await asset.load(.duration)
                duration = CMTimeGetSeconds(durationValue)
            } catch {
                duration = nil
            }

            // Generate thumbnail
            let thumbnail = await self?.generateThumbnail(for: url)

            await MainActor.run { [weak self] in
                guard let self = self else { return }

                if let index = self.videos.firstIndex(where: { $0.id == video.id }) {
                    var updatedVideo = self.videos[index]
                    updatedVideo.duration = duration
                    updatedVideo.thumbnail = thumbnail
                    self.videos[index] = updatedVideo
                }
            }
        }
    }

    private func generateThumbnail(for url: URL) async -> NSImage? {
        let asset = AVAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 192, height: 108)

        do {
            let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
            return NSImage(cgImage: cgImage, size: NSSize(width: 192, height: 108))
        } catch {
            return nil
        }
    }

    private func uniqueDestination(for url: URL) -> URL {
        var destination = url
        var counter = 1

        let directory = url.deletingLastPathComponent()
        let filename = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        while FileManager.default.fileExists(atPath: destination.path) {
            let newFilename = "\(filename) (\(counter)).\(ext)"
            destination = directory.appendingPathComponent(newFilename)
            counter += 1
        }

        return destination
    }
}
