//
//  MacOSWallpaperVideosSection.swift
//  Aerial Companion
//
//  Reclaiming macOS's own downloaded aerial wallpaper videos — *system*
//  storage Aerial helps tidy up, shown at the bottom of the Cache panel
//  (which otherwise manages Aerial's own video downloads).
//

import SwiftUI

struct MacOSWallpaperVideosSection: View {
    /// Mirrors `Preferences.reclaimMacOSWallpaperVideosAtStartup`.
    @State private var reclaimMacOSAtStartup: Bool = false
    @State private var macOSVideoBytes: Int64 = 0
    @State private var macOSVideoCount: Int = 0
    @State private var macOSUsageLoaded: Bool = false
    @State private var isReclaimingMacOSVideos: Bool = false
    /// Drives the "Reclaim Now" confirmation dialog.
    @State private var showReclaimConfirm: Bool = false

    /// macOS downloads its own aerial videos for the system wallpaper into
    /// ~/Library/Application Support/com.apple.wallpaper/aerials/videos and
    /// never prunes them. This section reports that usage and lets the user
    /// reclaim it (at startup and/or on demand). Distinct from Aerial's own
    /// video library.
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                if macOSUsageLoaded {
                    if macOSVideoCount > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "internaldrive")
                                .foregroundColor(.secondary)
                            Text("macOS has downloaded \(macOSVideoCount) video\(macOSVideoCount == 1 ? "" : "s"), using \(ByteCountFormatter.string(fromByteCount: macOSVideoBytes, countStyle: .file)).")
                                .font(.system(size: 13))
                        }
                    } else {
                        Text("No macOS wallpaper videos found — nothing to reclaim.")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Calculating disk usage…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }

                Toggle("Reclaim free space at startup by deleting macOS's video cache", isOn: $reclaimMacOSAtStartup)
                    .font(.system(size: 14))
                    .onChange(of: reclaimMacOSAtStartup) { newValue in
                        Preferences.reclaimMacOSWallpaperVideosAtStartup = newValue
                    }

                Text("macOS downloads its own aerial videos for the system wallpaper and never deletes them. If you use Aerial instead, they're wasted space — but if you do use a macOS aerial wallpaper, macOS will re-download what it needs.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                HStack {
                    Spacer()
                    Button("Reclaim Now…") {
                        showReclaimConfirm = true
                    }
                    .disabled(isReclaimingMacOSVideos || macOSVideoCount == 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        } label: {
            Label("macOS Wallpaper Videos", systemImage: "film.stack")
                .font(Font.title3.bold())
                .padding(4)
        }
        .confirmationDialog(
            "Delete macOS's downloaded wallpaper videos?",
            isPresented: $showReclaimConfirm,
            titleVisibility: .visible
        ) {
            Button("Reclaim \(ByteCountFormatter.string(fromByteCount: macOSVideoBytes, countStyle: .file))", role: .destructive) {
                reclaimMacOSVideosNow()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the aerial videos macOS downloaded for its own wallpaper. macOS will re-download them if you use a macOS aerial wallpaper.")
        }
        .onAppear {
            reclaimMacOSAtStartup = Preferences.reclaimMacOSWallpaperVideosAtStartup
            refreshMacOSUsage()
        }
    }

    /// Compute current macOS wallpaper-video usage off-main and publish to UI.
    private func refreshMacOSUsage() {
        DispatchQueue.global(qos: .utility).async {
            let usage = MacOSWallpaperVideoCache.currentUsage()
            DispatchQueue.main.async {
                macOSVideoBytes = usage.bytes
                macOSVideoCount = usage.count
                macOSUsageLoaded = true
            }
        }
    }

    /// Delete macOS's wallpaper videos off-main, then refresh displayed usage.
    private func reclaimMacOSVideosNow() {
        guard !isReclaimingMacOSVideos else { return }
        isReclaimingMacOSVideos = true
        DispatchQueue.global(qos: .utility).async {
            MacOSWallpaperVideoCache.reclaim()
            let usage = MacOSWallpaperVideoCache.currentUsage()
            DispatchQueue.main.async {
                macOSVideoBytes = usage.bytes
                macOSVideoCount = usage.count
                macOSUsageLoaded = true
                isReclaimingMacOSVideos = false
            }
        }
    }
}
