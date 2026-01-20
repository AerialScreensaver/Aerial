//
//  MyVideosSettingsPanel.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 20/01/2026.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Video Row View

@available(macOS 13.0, *)
struct VideoRowView: View {
    let video: LocalVideoInfo
    let onDelete: () -> Void
    let onReveal: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            ZStack {
                if let thumbnail = video.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 54)
                        .clipped()
                        .cornerRadius(4)
                } else if video.status == .valid {
                    // Loading placeholder for valid videos
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 96, height: 54)
                        .cornerRadius(4)
                        .overlay {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                } else {
                    // Warning icon for invalid files
                    Rectangle()
                        .fill(Color.orange.opacity(0.1))
                        .frame(width: 96, height: 54)
                        .cornerRadius(4)
                        .overlay {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 20))
                        }
                }
            }

            // File info
            VStack(alignment: .leading, spacing: 4) {
                Text(video.filename)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    // Status/Duration
                    if video.status == .valid {
                        if let duration = video.formattedDuration {
                            Label(duration, systemImage: "clock")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(video.status.description)
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }

                    // File size
                    Text(video.formattedSize)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    // File extension badge
                    Text(video.fileExtension)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(video.status == .valid ? Color.accentColor.opacity(0.2) : Color.orange.opacity(0.2))
                        .foregroundColor(video.status == .valid ? .accentColor : .orange)
                        .cornerRadius(3)
                }
            }

            Spacer()

            // Status indicator and actions
            if isHovering {
                HStack(spacing: 8) {
                    Button(action: onReveal) {
                        Image(systemName: "folder")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Move to Trash")
                }
            } else {
                // Status icon
                if video.status == .valid {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 16))
                } else {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 16))
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isHovering ? Color.secondary.opacity(0.1) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Drop Zone View

@available(macOS 13.0, *)
struct DropZoneView: View {
    @Binding var isTargeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                style: StrokeStyle(lineWidth: 2, dash: [8, 4])
            )
            .foregroundColor(isTargeted ? .accentColor : .secondary.opacity(0.5))
            .frame(height: 80)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 24))
                        .foregroundColor(isTargeted ? .accentColor : .secondary)

                    Text("Drop video files here to add them")
                        .font(.system(size: 13))
                        .foregroundColor(isTargeted ? .accentColor : .secondary)
                }
            }
    }
}

// MARK: - My Videos Settings Panel

@available(macOS 13.0, *)
struct MyVideosSettingsPanel: View {
    @StateObject private var viewModel = MyVideosViewModel()
    @State private var isDropTargeted = false
    @State private var showDeleteConfirmation = false
    @State private var videoToDelete: LocalVideoInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("My Videos")
                    .font(.system(size: 24, weight: .bold))

                Text("You can add your own videos here, or copy them manually in `/Users/Shared/Aerial/My Videos/`. Files cannot be played from other locations because of security restrictions in macOS. ")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Content
            if viewModel.isLoading {
                Spacer()
                ProgressView("Scanning folder...")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if viewModel.videos.isEmpty {
                // Empty state
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    Text("No videos found")
                        .font(.headline)

                    Text("Add videos by dragging them here or placing them in the My Videos folder")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)

                    Button("Open Folder in Finder") {
                        viewModel.openInFinder()
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                // Video list
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.videos) { video in
                            VideoRowView(
                                video: video,
                                onDelete: {
                                    videoToDelete = video
                                    showDeleteConfirmation = true
                                },
                                onReveal: {
                                    viewModel.revealInFinder(video)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }

            // Drop zone
            DropZoneView(isTargeted: $isDropTargeted)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers: providers)
                    return true
                }

            // Import progress
            if viewModel.isImporting {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(viewModel.importProgress)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            Divider()

            // Footer
            HStack {
                Button(action: { viewModel.openInFinder() }) {
                    Label("Open Folder", systemImage: "folder")
                }
                .controlSize(.large)

                Button(action: { viewModel.scanFolder() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)

                Spacer()

                // Stats
                let validCount = viewModel.videos.filter { $0.status == .valid }.count
                let totalCount = viewModel.videos.count

                if totalCount > 0 {
                    if validCount == totalCount {
                        Text("\(validCount) video\(validCount == 1 ? "" : "s")")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(validCount) video\(validCount == 1 ? "" : "s"), \(totalCount - validCount) ignored")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            viewModel.scanFolder()
        }
        .alert("Delete Video", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                videoToDelete = nil
            }
            Button("Move to Trash", role: .destructive) {
                if let video = videoToDelete {
                    viewModel.deleteVideo(video)
                }
                videoToDelete = nil
            }
        } message: {
            if let video = videoToDelete {
                Text("Are you sure you want to move '\(video.filename)' to the Trash?")
            }
        }
    }

    // MARK: - Private Methods

    private func handleDrop(providers: [NSItemProvider]) {
        var urls: [URL] = []

        let group = DispatchGroup()

        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        // Only accept video files
                        let ext = url.pathExtension.lowercased()
                        if ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext) {
                            urls.append(url)
                        }
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty {
                viewModel.importVideos(urls: urls)
            }
        }
    }
}

// MARK: - Preview

@available(macOS 13.0, *)
struct MyVideosSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        MyVideosSettingsPanel()
            .frame(width: 500, height: 600)
    }
}
