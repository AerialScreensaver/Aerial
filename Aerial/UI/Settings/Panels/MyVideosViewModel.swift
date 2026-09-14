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

enum LocalVideoStatus: Equatable {
    case valid
    case tooSmall           // < 500KB
    case unsupportedFormat  // not .mp4/.mov
    case needsConversion    // .mkv/.webm — playable after an ffmpeg remux

    var description: String {
        switch self {
        case .valid:
            return "Ready to play"
        case .tooSmall:
            return "File too small (< 500KB)"
        case .unsupportedFormat:
            return "Unsupported format"
        case .needsConversion:
            return "Needs conversion to MP4"
        }
    }

    var isPlayable: Bool {
        self == .valid
    }
}

// MARK: - Local Video Info

struct LocalVideoInfo: Identifiable, Equatable {
    let id: String
    let filename: String
    var title: String
    let path: String
    let fileSize: Int64
    let status: LocalVideoStatus
    var duration: TimeInterval?
    var thumbnail: NSImage?
    /// The persistent asset id from entries.json (nil until the library
    /// has scanned the file) — the key for time-of-day overrides.
    var manifestId: String?
    /// Manifest values, for the tagging menus.
    var manifestTimeOfDay: String?
    var scene: String?
    /// Current effective time-of-day override, nil = manifest value.
    var timeOfDayOverride: String?

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
        lhs.title == rhs.title &&
        lhs.path == rhs.path &&
        lhs.fileSize == rhs.fileSize &&
        lhs.status == rhs.status &&
        lhs.duration == rhs.duration &&
        lhs.scene == rhs.scene &&
        lhs.timeOfDayOverride == rhs.timeOfDayOverride
    }
}

// MARK: - My Videos View Model

@MainActor
class MyVideosViewModel: ObservableObject {
    @Published var videos: [LocalVideoInfo] = []
    @Published var isLoading: Bool = false
    @Published var isImporting: Bool = false
    @Published var importProgress: String = ""
    @Published var errorMessage: String? = nil

    private let folderPath = AerialPaths.myVideosPath()
    private var errorDismissTask: Task<Void, Never>?
    private let supportedExtensions = ["mp4", "mov"]
    /// Containers AVFoundation can't read but ffmpeg can losslessly
    /// remux to .mp4 when the video codec is H.264/HEVC.
    private let convertibleExtensions = ["mkv", "webm"]
    private let minimumFileSize: Int64 = 500_000  // 500KB

    // MARK: - Public Methods

    func showError(_ message: String, duration: Double = 4.0) {
        errorDismissTask?.cancel()
        errorMessage = message
        errorDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if !Task.isCancelled {
                self.errorMessage = nil
            }
        }
    }

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
                let ext = url.pathExtension.lowercased()

                if convertibleExtensions.contains(ext) {
                    // AVFoundation can't read these containers — remux
                    // to .mp4 on the way in (lossless when the codec is
                    // H.264/HEVC; anything else is rejected).
                    importProgress = "Converting \(filename)..."
                    let mp4Name = url.deletingPathExtension().lastPathComponent + ".mp4"
                    let destination = uniqueDestination(
                        for: URL(fileURLWithPath: folderPath).appendingPathComponent(mp4Name)
                    )
                    do {
                        try await remuxToMP4(source: url, destination: destination)
                        importedCount += 1
                    } catch {
                        errorLog("Failed to convert \(filename): \(error.localizedDescription)")
                        showError("\(filename): \(error.localizedDescription)", duration: 6)
                    }
                } else {
                    let destinationURL = URL(fileURLWithPath: folderPath).appendingPathComponent(filename)
                    let finalDestination = uniqueDestination(for: destinationURL)
                    do {
                        try FileManager.default.copyItem(at: url, to: finalDestination)
                        importedCount += 1
                    } catch {
                        errorLog("Failed to import \(filename): \(error.localizedDescription)")
                    }
                }
                importProgress = "Imported \(importedCount) of \(urls.count)..."
            }

            // Refresh the source list so Aerial picks up new videos
            SourceList.ensureDefaultLocalSource()

            // Rescan the folder
            scanFolder()

            isImporting = false
            importProgress = ""
        }
    }

    /// Convert an .mkv/.webm sitting IN the folder (Finder drop) to a
    /// playable .mp4; the original moves to the Trash on success.
    func convertVideo(_ video: LocalVideoInfo) {
        guard video.status == .needsConversion else { return }
        isImporting = true
        importProgress = "Converting \(video.filename)..."

        Task {
            let source = URL(fileURLWithPath: video.path)
            let mp4Name = source.deletingPathExtension().lastPathComponent + ".mp4"
            let destination = uniqueDestination(
                for: URL(fileURLWithPath: folderPath).appendingPathComponent(mp4Name)
            )
            do {
                try await remuxToMP4(source: source, destination: destination)
                try? FileManager.default.trashItem(at: source, resultingItemURL: nil)
                SourceList.ensureDefaultLocalSource()
                scanFolder()
            } catch {
                errorLog("Failed to convert \(video.filename): \(error.localizedDescription)")
                showError("\(video.filename): \(error.localizedDescription)", duration: 6)
            }
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
            errorLog("Failed to delete \(video.filename): \(error.localizedDescription)")
        }
    }

    func openInFinder() {
        let url = URL(fileURLWithPath: folderPath)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    func revealInFinder(_ video: LocalVideoInfo) {
        NSWorkspace.shared.selectFile(video.path, inFileViewerRootedAtPath: folderPath)
    }

    func updateVideoTitle(_ video: LocalVideoInfo, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Update in local array
        if let index = videos.firstIndex(where: { $0.id == video.id }) {
            videos[index].title = trimmed
        }

        // Persist to entries.json
        let entriesPath = Cache.supportPath.appending("/Sources/My Videos/entries.json")
        guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: entriesPath)),
              let manifest = try? newJSONDecoder().decode(VideoManifest.self, from: jsonData) else {
            return
        }

        let updatedAssets = manifest.assets.map { asset -> VideoAsset in
            if asset.url4KSDR == video.path {
                return VideoAsset(
                    accessibilityLabel: asset.accessibilityLabel,
                    id: asset.id,
                    title: trimmed,
                    timeOfDay: asset.timeOfDay,
                    scene: asset.scene,
                    pointsOfInterest: asset.pointsOfInterest,
                    url4KHDR: asset.url4KHDR,
                    url4KSDR: asset.url4KSDR,
                    url1080H264: asset.url1080H264,
                    url1080HDR: asset.url1080HDR,
                    url4KSDR120FPS: asset.url4KSDR120FPS,
                    url4KSDR240FPS: asset.url4KSDR240FPS,
                    url1080SDR: asset.url1080SDR,
                    url: asset.url,
                    type: asset.type,
                    isLive: asset.isLive,
                    livePlaybackSeconds: asset.livePlaybackSeconds
                )
            }
            return asset
        }

        let updatedManifest = VideoManifest(assets: updatedAssets, initialAssetCount: manifest.initialAssetCount, version: manifest.version)

        // Find the My Videos source and save
        if let source = SourceList.list.first(where: { $0.name == "My Videos" && $0.type == .local }) {
            SourceList.saveEntries(source: source, manifest: updatedManifest)
        }
    }

    // MARK: - Private Methods

    private func performScan() async -> [LocalVideoInfo] {
        let url = URL(fileURLWithPath: folderPath)

        guard FileManager.default.fileExists(atPath: folderPath) else {
            errorLog("My Videos folder doesn't exist: \(folderPath)")
            return []
        }

        // Load existing entries.json to get saved titles + the
        // persistent asset id / tags for each file (keyed by path — the
        // same match `updateVideoTitle` uses).
        var titlesByPath: [String: String] = [:]
        var assetsByPath: [String: (id: String, timeOfDay: String?, scene: String?)] = [:]
        let entriesPath = Cache.supportPath.appending("/Sources/My Videos/entries.json")
        if let jsonData = try? Data(contentsOf: URL(fileURLWithPath: entriesPath)),
           let manifest = try? newJSONDecoder().decode(VideoManifest.self, from: jsonData) {
            for asset in manifest.assets {
                if let path = asset.url4KSDR {
                    titlesByPath[path] = asset.title
                    assetsByPath[path] = (asset.id, asset.timeOfDay, asset.scene)
                }
            }
        }
        let overrides = PrefsVideos.timeOfDayOverride

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

                if convertibleExtensions.contains(ext) {
                    status = .needsConversion
                } else if !supportedExtensions.contains(ext) {
                    status = .unsupportedFormat
                } else if fileSize < minimumFileSize && !isSymbolicLink {
                    status = .tooSmall
                } else {
                    status = .valid
                }

                let filename = fileUrl.lastPathComponent
                let filenameWithoutExt = fileUrl.deletingPathExtension().lastPathComponent

                // Use saved title from entries.json if it differs from filename, otherwise use filename without extension
                let savedTitle = titlesByPath[fileUrl.path]
                let title: String
                if let savedTitle = savedTitle, savedTitle != filename {
                    title = savedTitle
                } else {
                    title = filenameWithoutExt
                }

                let asset = assetsByPath[fileUrl.path]
                let video = LocalVideoInfo(
                    id: UUID().uuidString,
                    filename: filename,
                    title: title,
                    path: fileUrl.path,
                    fileSize: fileSize,
                    status: status,
                    duration: nil,
                    thumbnail: nil,
                    manifestId: asset?.id,
                    manifestTimeOfDay: asset?.timeOfDay,
                    scene: asset?.scene,
                    timeOfDayOverride: asset.flatMap { overrides[$0.id] }
                )

                results.append(video)
            }
        } catch {
            errorLog("Failed to scan My Videos folder: \(error.localizedDescription)")
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

    // MARK: - Tagging (time of day / scene)

    /// Set (or clear, with nil) the time-of-day override for a local
    /// video — same pref map + live-video mutation the inspector's
    /// TimeOfDayOverrideView uses; filtering picks it up at the next
    /// rotation/regeneration.
    func setTimeOfDay(_ video: LocalVideoInfo, value: String?) {
        guard let manifestId = video.manifestId else { return }

        var overrides = PrefsVideos.timeOfDayOverride
        if let value {
            overrides[manifestId] = value
        } else {
            overrides.removeValue(forKey: manifestId)
        }
        PrefsVideos.timeOfDayOverride = overrides

        // Keep the loaded library consistent without a full reload.
        if let live = VideoList.instance.videos.first(where: { $0.id == manifestId }) {
            live.timeOfDay = value ?? live.manifestTimeOfDay
        }
        if let index = videos.firstIndex(where: { $0.id == video.id }) {
            videos[index].timeOfDayOverride = value
        }
    }

    /// Set the scene tag — rewrites the asset in entries.json (the
    /// SceneEditorView mechanism) and mutates the loaded video.
    func setScene(_ video: LocalVideoInfo, sceneValue: String) {
        guard let manifestId = video.manifestId else { return }

        let entriesPath = Cache.supportPath.appending("/Sources/My Videos/entries.json")
        guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: entriesPath)),
              let manifest = try? newJSONDecoder().decode(VideoManifest.self, from: jsonData) else {
            return
        }

        let updatedAssets = manifest.assets.map { asset -> VideoAsset in
            guard asset.id == manifestId else { return asset }
            return VideoAsset(
                accessibilityLabel: asset.accessibilityLabel,
                id: asset.id,
                title: asset.title,
                timeOfDay: asset.timeOfDay,
                scene: sceneValue,
                pointsOfInterest: asset.pointsOfInterest,
                url4KHDR: asset.url4KHDR,
                url4KSDR: asset.url4KSDR,
                url1080H264: asset.url1080H264,
                url1080HDR: asset.url1080HDR,
                url4KSDR120FPS: asset.url4KSDR120FPS,
                url4KSDR240FPS: asset.url4KSDR240FPS,
                url1080SDR: asset.url1080SDR,
                url: asset.url,
                type: asset.type,
                isLive: asset.isLive,
                livePlaybackSeconds: asset.livePlaybackSeconds
            )
        }
        let updatedManifest = VideoManifest(
            assets: updatedAssets,
            initialAssetCount: manifest.initialAssetCount,
            version: manifest.version
        )
        if let source = SourceList.list.first(where: { $0.name == "My Videos" && $0.type == .local }) {
            SourceList.saveEntries(source: source, manifest: updatedManifest)
        }

        if let live = VideoList.instance.videos.first(where: { $0.id == manifestId }) {
            live.scene = SourceScene(rawValue: sceneValue) ?? live.scene
        }
        if let index = videos.firstIndex(where: { $0.id == video.id }) {
            videos[index].scene = sceneValue
        }
    }

    // MARK: - mkv/webm remux (ffmpeg)

    private struct ConversionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Lossless remux into .mp4 — video/audio streams copied, data and
    /// subtitle tracks dropped (they don't survive the mp4 muxer).
    /// Requires ffmpeg + an H.264/HEVC video stream; fails with a
    /// user-readable message otherwise. Probe and remux both run off
    /// the main actor.
    private func remuxToMP4(source: URL, destination: URL) async throws {
        guard let ffmpeg = LiveFeedsTooling.shared.ffmpegPath else {
            throw ConversionError(message: "ffmpeg not found — install it with `brew install ffmpeg`")
        }
        let ffprobe = LiveFeedsTooling.shared.ffprobePath

        let failure: ConversionError? = await Task.detached {
            // Codec gate first — a clean message beats an ffmpeg muxer
            // error. Skipped when ffprobe is missing (ffmpeg then
            // succeeds or fails on its own).
            if let ffprobe, let codec = Self.probeVideoCodec(source, ffprobe: ffprobe),
               !["h264", "hevc"].contains(codec) {
                return ConversionError(message: "video codec '\(codec)' can't play on macOS — needs H.264 or HEVC")
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = [
                "-y", "-i", source.path,
                "-map", "0:v:0", "-map", "0:a?",
                "-c", "copy", "-sn", "-dn",
                "-movflags", "+faststart",
                destination.path,
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return ConversionError(message: "couldn't run ffmpeg: \(error.localizedDescription)")
            }
            guard process.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: destination.path) else {
                try? FileManager.default.removeItem(at: destination)
                return ConversionError(message: "conversion failed — the streams may not be MP4-compatible")
            }
            return nil
        }.value

        if let failure { throw failure }
    }

    /// First video stream's codec name via ffprobe.
    private nonisolated static func probeVideoCodec(_ url: URL, ffprobe: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=codec_name",
            "-of", "csv=p=0",
            url.path,
        ]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : output
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
