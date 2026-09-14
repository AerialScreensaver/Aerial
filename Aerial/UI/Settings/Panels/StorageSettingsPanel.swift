//
//  StorageSettingsPanel.swift
//  Aerial Companion
//
//  Disk-reclaim tools that used to live at the bottom of the Wallpaper
//  panel, gathered into their own category:
//   • the wallpaper-agent image-cache cleaner (the cache the legacy
//     "continuity" feature filled via setDesktopImageURL — macOS 26+
//     never prunes it on its own), and
//   • reclaiming macOS's own downloaded aerial videos.
//
//  Both are about *system* storage Aerial helps tidy up — distinct from
//  the "Cache" panel, which manages Aerial's own video downloads.
//

import SwiftUI

struct StorageSettingsPanel: View {
    // MARK: - Wallpaper-agent image cache (macOS 26+)
    /// Mirrors `Preferences.cleanWallpaperCache`.
    @State private var cleanWallpaperCache: Bool = true
    /// Mirrors `WallpaperCacheCleaner.shared.hasBookmark`.
    @State private var hasCacheAccess: Bool = false

    // MARK: - macOS wallpaper-video reclaim
    /// Mirrors `Preferences.reclaimMacOSWallpaperVideosAtStartup`.
    @State private var reclaimMacOSAtStartup: Bool = false
    @State private var macOSVideoBytes: Int64 = 0
    @State private var macOSVideoCount: Int = 0
    @State private var macOSUsageLoaded: Bool = false
    @State private var isReclaimingMacOSVideos: Bool = false
    /// Drives the "Reclaim Now" confirmation dialog.
    @State private var showReclaimConfirm: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Storage")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)

                // The wallpaper-agent image cache only balloons (and only
                // exists as a problem) on macOS 26+. On earlier systems
                // there's nothing to show here.
                if #available(macOS 26.0, *) {
                    wallpaperCacheSection
                }

                macOSVideoCacheSection

                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            cleanWallpaperCache = Preferences.cleanWallpaperCache
            hasCacheAccess = WallpaperCacheCleaner.shared.hasBookmark
            reclaimMacOSAtStartup = Preferences.reclaimMacOSWallpaperVideosAtStartup
            refreshMacOSUsage()
        }
    }

    // MARK: - Wallpaper-agent image cache

    /// Standalone cleaner for macOS's wallpaper-agent image cache. This
    /// is the cache the legacy continuity feature filled (and that macOS
    /// 26+ never prunes); kept available so users who ran continuity
    /// before upgrading can reclaim the space even though continuity no
    /// longer runs on Sonoma+.
    private var wallpaperCacheSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Automatically clean wallpaper cache", isOn: $cleanWallpaperCache)
                    .font(.system(size: 14))
                    .onChange(of: cleanWallpaperCache) { newValue in
                        Preferences.cleanWallpaperCache = newValue
                        WallpaperCacheCleaner.shared.reevaluate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            hasCacheAccess = WallpaperCacheCleaner.shared.hasBookmark
                        }
                    }

                Text("macOS 26 never prunes its wallpaper-image cache. If you've used Aerial's wallpaper continuity it can grow to many GB over time; Aerial keeps it under 2 GB.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                if cleanWallpaperCache && !hasCacheAccess {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("Access not yet granted — the cleaner can't run until you allow it.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Grant Access…") {
                            Task { @MainActor in
                                _ = await WallpaperCacheCleaner.shared.requestAccess()
                                hasCacheAccess = WallpaperCacheCleaner.shared.hasBookmark
                                // Granting may unblock monitoring.
                                WallpaperCacheCleaner.shared.reevaluate()
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(12)
        } label: {
            Label("Wallpaper Cache", systemImage: "internaldrive")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    // MARK: - macOS Wallpaper Video Cache

    /// macOS downloads its own aerial videos for the system wallpaper into
    /// ~/Library/Application Support/com.apple.wallpaper/aerials/videos and
    /// never prunes them. This section reports that usage and lets the user
    /// reclaim it (at startup and/or on demand). Distinct from the wallpaper
    /// *image* cache above, and from Aerial's own video library.
    private var macOSVideoCacheSection: some View {
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

// MARK: - Preview

struct StorageSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        StorageSettingsPanel()
            .frame(width: 500, height: 400)
    }
}
