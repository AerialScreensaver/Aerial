//
//  CacheSettingsPanel.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 08/02/2026.
//

import SwiftUI
import CoreLocation

struct CacheSettingsPanel: View {
    // Disk usage
    @State private var cacheSize: Double = 0
    @State private var packsSize: Double = 0
    @State private var cacheSizeString: String = ""
    @State private var sizesLoaded = false
    @State private var isTrimming = false

    // Downloads
    @State private var enableManagement = true
    @State private var unlimitedCache = false
    @State private var cacheLimit: Double = 5
    @State private var cachePeriodicity: CachePeriodicity = .never
    @State private var dockDownloadBadge = true
    // Network
    @State private var restrictOnWiFi = false
    @State private var currentSSID: String = ""
    @State private var allowedNetworks: [String] = []
    /// Cached Core Location authorization status. `CWInterface.ssid()`
    /// returns nil when this isn't `.authorizedAlways` or
    /// `.authorizedWhenInUse`, regardless of actual Wi-Fi state — so
    /// the panel needs this to distinguish "not on Wi-Fi" from
    /// "Location permission missing".
    @State private var locationAuth: CLAuthorizationStatus = .notDetermined

    // Storage
    @State private var excludeTimeMachine = false
    /// Exclusion state as last read from / written to tmutil. nil until
    /// the async read completes; the toggle's onChange only acts when the
    /// new value differs from this, so a programmatic load never spawns
    /// tmutil (11 s on a sparsebundle).
    @State private var timeMachineOnDisk: Bool?

    // Location
    @State private var useCustomLocation = false
    @State private var customCachePath: String = ""
    @State private var isMigrating = false
    @State private var migrationFilesDone = 0
    @State private var migrationFilesTotal = 0
    // External cache disk image (cache kept on an external drive)
    @State private var externalImageState: ExternalCacheImage.State = .off
    @State private var externalImageFolder: String = ""
    @State private var externalStepText: String = ""
    @State private var externalError: String?

    // Expansion packs at the cache location (`<location>/Expansions`)
    @State private var expansionsAtLocation = false
    @State private var movablePacksOffer: MovablePacksOffer?
    @State private var isMovingPacks = false
    @State private var packsMovedCount = 0
    /// Detach deferred until a "move packs back" sheet is dismissed —
    /// the packs must leave the image before it is unmounted.
    @State private var pendingDetachReason: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Cache")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)

                diskUsageSection
                locationSection
                downloadsSection
                networkSection
                storageSection

                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .task {
            loadSettings()
            await loadSizes()
        }
        .onReceive(NotificationCenter.default.publisher(for: ExternalCacheImage.stateDidChangeNotification)) { _ in
            externalImageState = ExternalCacheImage.shared.state
            if externalStepText == "Attaching…" {
                externalStepText = ""
                isMigrating = false
            }
            Task { await loadSizes() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ExternalCacheImage.attachFailedNotification)) { note in
            externalError = note.userInfo?["error"] as? String
            if externalStepText == "Attaching…" {
                externalStepText = ""
                isMigrating = false
            }
        }
    }

    // MARK: - Disk Usage

    private var diskUsageSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if isTrimming {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Trimming cache…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                } else if sizesLoaded {
                    diskUsageBar
                    HStack(alignment: .center) {
                        diskUsageLegend
                        Spacer()
                        if canTrimCache {
                            Button("Trim Cache to Limit…") {
                                trimCache()
                            }
                        }
                    }
                    if packsSize > 0.01 {
                        packsLine
                    }
                    Text("Your cache takes \(cacheSizeString) of disk space")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Calculating disk usage...")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)
        } label: {
            Label("Disk Usage", systemImage: "internaldrive")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    /// The bar is the CACHE BUDGET only: cache used, over-budget part,
    /// free. Expansion packs are stored beside the cache and never count
    /// against the limit (`Cache.hasSomeFreeSpace` compares the cache
    /// folder alone), so they get their own line below instead of a
    /// segment here. Over budget is drawn, not rescaled away.
    private var diskUsageBar: some View {
        let over = unlimitedCache ? 0.0 : max(0, cacheSize - cacheLimit)
        let used = unlimitedCache ? cacheSize : min(cacheSize, cacheLimit)
        let free = unlimitedCache ? 0.0 : max(0, cacheLimit - cacheSize)
        let total = unlimitedCache ? max(cacheSize, 0.001) : max(cacheLimit, cacheSize)
        let segments: [(color: Color, size: Double)] = [
            (Color.indigo, used),
            (Color.orange, over),
            (Color.gray.opacity(0.3), free),
        ].filter { $0.size > 0.01 }

        return GeometryReader { geo in
            let spacing: CGFloat = 2
            let available = max(0, geo.size.width - spacing * CGFloat(max(0, segments.count - 1)))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.12))
                HStack(spacing: spacing) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(segment.color)
                            .frame(width: max(2, available * segment.size / total))
                    }
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipShape(Capsule())
        }
        .frame(height: 20)
    }

    private var diskUsageLegend: some View {
        HStack(spacing: 16) {
            legendItem(color: .indigo, label: "Cache: \(String(format: "%.1f", cacheSize)) GB")
            if !unlimitedCache {
                let over = cacheSize - cacheLimit
                if over > 0.05 {
                    legendItem(color: .orange, label: "Over by \(String(format: "%.1f", over)) GB")
                } else {
                    legendItem(color: .gray.opacity(0.3), label: "Free: \(String(format: "%.1f", max(0, -over))) GB")
                }
            }
        }
    }

    /// Over budget and trimmable: the scheduler only evicts on its cadence
    /// (never when Replace = Never), so lowering the limit leaves the cache
    /// orange until the user asks.
    private var canTrimCache: Bool {
        !unlimitedCache && cacheSize > cacheLimit + 0.05 && Cache.isAvailable
    }

    /// Plan off-main, confirm with the exact count/size, delete off-main,
    /// then regenerate playlists (the extension advances away from deleted
    /// entries) and refresh every size display.
    private func trimCache() {
        let protected = WallpaperStatusMonitor.nowPlayingVideoIds()
        let limit = cacheLimit
        Task {
            let plan = await Task.detached(priority: .userInitiated) {
                Cache.trimPlan(protecting: protected)
            }.value
            let alert = NSAlert()
            guard !plan.isEmpty else {
                alert.messageText = "Nothing to trim"
                alert.informativeText = "Every cached video is either a favourite or playing right now, so the cache can't be trimmed any further."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            let count = plan.videos.count
            let plural = count == 1 ? "" : "s"
            let gigabytes = String(format: "%.1f", Double(plan.bytes) / 1e9)
            alert.messageText = "Trim the cache to \(Int(limit)) GB?"
            alert.informativeText = "This will delete \(count) video\(plural) (\(gigabytes) GB), oldest first. Favourites and the videos playing right now are kept. Deleted videos can be downloaded again later."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete \(count) Video\(plural)").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            isTrimming = true
            let result = await Task.detached(priority: .userInitiated) {
                Cache.applyTrim(plan)
            }.value
            debugLog("Cache trim: user trimmed \(result.removed) video(s)")
            // Same sequence the video browser's delete uses: drop the entries
            // from every playlist (bumps playlistGeneration for the extension),
            // then let the dashboard ring / browser refresh their sizes.
            PlaylistManager.shared.regenerateAll()
            NotificationCenter.default.post(name: DownloadCoordinator.downloadDidCompleteNotification, object: nil)
            isTrimming = false
            await loadSizes()
        }
    }

    /// Packs live outside the budget — their own line (mint, so the colour
    /// still reads as "packs" for anyone used to the old bar).
    private var packsLine: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.mint)
                .frame(width: 8, height: 8)
            Text("Expansion packs: \(String(format: "%.1f", packsSize)) GB — stored beside the cache, not counted in the limit")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Location

    private var locationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Current path:")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text(Cache.path)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Toggle("Use Custom Location for Cache", isOn: $useCustomLocation)
                    .font(.system(size: 14))
                    .onChange(of: useCustomLocation) { newValue in
                        // Only a user flip — loadSettings sets it to the pref
                        // value (e.g. after a legacy folder moved to the default).
                        guard newValue != PrefsCache.overrideCache else { return }
                        if !newValue {
                            resetToDefaultLocation()
                        }
                    }

                if useCustomLocation {
                    HStack(spacing: 12) {
                        Text(customCachePath.isEmpty ? "No folder selected" : customCachePath)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Choose Folder...") {
                            pickCacheFolder()
                        }
                        .disabled(isMigrating)
                    }

                    if let legacyFolder = Cache.legacyExternalFolderPath {
                        legacyExternalFolderRow(legacyFolder)
                    }

                    if externalImageState != .off {
                        externalImageStatusRow
                    }

                    expansionsSubOption
                }

                if isMigrating {
                    HStack(spacing: 8) {
                        if migrationFilesTotal > 0 {
                            ProgressView(value: Double(migrationFilesDone), total: Double(migrationFilesTotal))
                                .frame(maxWidth: .infinity)
                            Text("\(migrationFilesDone)/\(migrationFilesTotal)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                            Text(externalStepText.isEmpty ? "Working…" : externalStepText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let externalError, externalImageState == .off {
                    // Image mode shows its errors in the status row; a legacy
                    // folder moved to the default location has no row left to
                    // show them in (the custom-location block is gone).
                    Label(externalError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

            }
            .padding(12)
        } label: {
            Label("Location", systemImage: "folder")
                .font(Font.title3.bold())
                .padding(4)
        }
        .sheet(item: $movablePacksOffer) { offer in
            // item-based so the content always renders with the packs it
            // was presented for (isPresented-based sheets can capture the
            // pre-presentation state — the "0 packs" render).
            MoveExpansionsSheet(
                packs: offer.packs,
                destination: offer.destination,
                isMoving: isMovingPacks,
                movedCount: packsMovedCount,
                onMove: { movePacks(offer) },
                onManual: {
                    movablePacksOffer = nil
                    runPendingDetach()
                }
            )
        }
    }

    private func pickCacheFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose a folder for the video cache. Outside /Users/Shared (an external drive, your home folder…), Aerial keeps the videos in a disk image the wallpaper extension can read."
        panel.begin { result in
            guard result == .OK, let url = panel.urls.first else { return }
            confirmAndApply(newPath: url.path)
        }
    }

    private func confirmAndApply(newPath: String) {
        let resolved = URL(fileURLWithPath: newPath).resolvingSymlinksInPath().path
        let mountPoint = Cache.externalCacheMountPoint
        if resolved == mountPoint || resolved.hasPrefix(mountPoint + "/") {
            // Aerial's own plumbing, not a user location.
            let alert = NSAlert()
            alert.messageText = "Please choose a different folder"
            alert.informativeText = "This folder is the mount point Aerial uses for the external cache image. Choose the folder that should hold the cache instead."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        // The wallpaper extension can only read paths below /Users/Shared.
        // Put every other custom location (including ~/… and /Volumes/…)
        // behind a disk image mounted in the shared support directory.
        let wantsImage = !Cache.isExtensionReadablePath(resolved)
        let currentPath = Cache.path
        let currentDisplayPath = Cache.isExternalImageMode ? externalImageFolder : currentPath

        // A network share only holds the image when its server supports
        // full-sync writes. Say so before any question about moving
        // videos, and leave the configuration untouched.
        if wantsImage, let problem = ExternalCacheImage.imageHostingProblem(folder: resolved) {
            errorLog("💽 rejected cache folder \(resolved): \(problem)")
            let alert = NSAlert()
            alert.messageText = "This folder can't hold the cache image"
            alert.informativeText = problem
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        // A plain folder awaiting conversion picked again — the obvious self-fix
        // when the wallpaper shows nothing — converts IN PLACE instead of
        // counting as "same location". The image is created inside the
        // folder and its videos move in (adoptSiblingVideos), so there is
        // no "start fresh" here: keeping them outside the image would just
        // leave them unplayable next to it.
        if let legacy = Cache.legacyExternalFolderPath,
           resolved == URL(fileURLWithPath: legacy).resolvingSymlinksInPath().path {
            let inventory = LegacyExternalCacheMigration.inventory(folder: legacy)
            let alert = NSAlert()
            alert.messageText = "Move the videos in this folder into a disk image?"
            alert.informativeText = "Aerial keeps caches outside /Users/Shared in a disk image (\(ExternalCacheImage.bundleName)) so the wallpaper extension can play them. The image is created inside this folder and the \(inventory.count) video\(inventory.count == 1 ? "" : "s") in it (\(inventory.formattedBytes)), plus any Expansion packs, are moved in. Nothing is deleted."
            alert.addButton(withTitle: "Convert")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .informational
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            applyExternalCache(folder: legacy, migrateFrom: nil)
            return
        }

        // Same location as today — nothing to do.
        guard newPath != currentDisplayPath, resolved != currentPath else { return }

        // Moving out of an image needs it attached; drive → drive can't
        // move (one mount point, one image) — those offer "Start fresh" only.
        let canMigrate = Cache.isExternalImageMode ? (!wantsImage && Cache.isAvailable) : true

        let alert = NSAlert()
        alert.messageText = "Change cache location?"
        let packsNote = PrefsCache.expansionsAtCacheLocation
            ? " Expansion packs stored at the cache location move along with the videos."
            : ""
        if wantsImage {
            let networkNote = ExternalCacheImage.volumeIsNetwork(resolved)
                ? " This folder is on a network share: the videos stream over the network, and the desktop only has them while the share is mounted."
                : ""
            alert.informativeText = "Aerial will create a disk image (\(ExternalCacheImage.bundleName)) in this folder and keep the videos inside it, so the wallpaper extension can play them from this folder.\(networkNote)\n\nWhat would you like to do with the videos in the current cache?\(packsNote)"
        } else {
            alert.informativeText = "What would you like to do with videos in the current cache folder?\(packsNote)"
        }
        if canMigrate {
            alert.addButton(withTitle: "Move existing videos")
        }
        alert.addButton(withTitle: "Start fresh (keep old)")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational

        let response = alert.runModal()
        let migrate: Bool
        switch (canMigrate, response) {
        case (true, .alertFirstButtonReturn):
            migrate = true
        case (true, .alertSecondButtonReturn), (false, .alertFirstButtonReturn):
            migrate = false
        default:
            return
        }

        if wantsImage {
            applyExternalCache(folder: newPath, migrateFrom: migrate ? currentPath : nil)
            return
        }

        // Plain folder. Leaving an image: prefs first so downloads target
        // the new folder, move the videos out of the still-attached image,
        // then detach it (off-main — a busy volume makes hdiutil spin).
        let leavingImage = Cache.isExternalImageMode
        let oldPacksRoot = PrefsCache.expansionsAtCacheLocation ? Cache.expansionsRootCandidate : nil
        if leavingImage {
            PrefsCache.externalCacheImagePath = nil
            externalImageFolder = ""
        }
        applyCachePath(newPath)
        let finish = {
            if leavingImage {
                detachInBackground(reason: "settings: plain folder")
            }
        }
        if migrate {
            let packs = oldPacksRoot.map { (from: $0, to: newPath.appending("/Expansions")) }
            migrateVideos(from: currentPath, to: newPath, packs: packs, completion: finish)
        } else {
            finish()
        }
    }

    /// Detach with the busy indicator up; never blocks the UI.
    private func detachInBackground(reason: String) {
        isMigrating = true
        migrationFilesTotal = 0
        externalStepText = "Detaching…"
        Task {
            await ExternalCacheImage.shared.detachIfAttached(reason: reason, mode: .escalate)
            externalImageState = ExternalCacheImage.shared.state
            externalStepText = ""
            isMigrating = false
        }
    }

    private func applyCachePath(_ newPath: String) {
        PrefsCache.cachePath = newPath
        PrefsCache.overrideCache = true
        Cache.invalidateCachePath()
        customCachePath = newPath
        ExternalCacheImage.refreshConsumers(reason: "settings: cache path")
        Task {
            await loadSizes()
        }
    }

    private func resetToDefaultLocation() {
        let leavingImage = Cache.isExternalImageMode
        // Packs at the location: offer to bring them back to the default
        // root — computed BEFORE the prefs change drops that root from the
        // scan, and moved BEFORE the image is detached.
        let packsRoot = PrefsCache.expansionsAtCacheLocation ? Cache.expansionsRootCandidate : nil
        let packsToMove = packsRoot.map { installedPacks(inRoot: $0) } ?? []
        if leavingImage {
            // The videos stay inside the image on the drive; choosing that
            // folder again later brings them back.
            PrefsCache.externalCacheImagePath = nil
            externalImageFolder = ""
        }
        PrefsCache.expansionsAtCacheLocation = false
        expansionsAtLocation = false
        PrefsCache.overrideCache = false
        PrefsCache.cachePath = nil
        Cache.invalidateCachePath()
        customCachePath = ""
        ExternalCacheImage.refreshConsumers(reason: "settings: default cache")
        if !packsToMove.isEmpty {
            pendingDetachReason = leavingImage ? "settings: default location" : nil
            offerToMove(packsToMove, to: Cache.defaultSourcesRoot)
        } else if leavingImage {
            detachInBackground(reason: "settings: default location")
        }
        Task {
            await loadSizes()
        }
    }

    // MARK: - Expansion packs at the cache location

    /// Sub-option of the custom cache location: keep Expansion packs in an
    /// `Expansions/` folder beside the videos (inside the disk image on an
    /// external drive, where the wallpaper extension can play them).
    private var expansionsSubOption: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Also store Expansion packs at this location", isOn: $expansionsAtLocation)
                .font(.system(size: 13))
                .disabled(customCachePath.isEmpty || isMigrating || isMovingPacks)
                .onChange(of: expansionsAtLocation) { newValue in
                    // Only a user flip — loadSettings sets it to the pref value.
                    guard newValue != PrefsCache.expansionsAtCacheLocation else { return }
                    setExpansionsAtLocation(newValue)
                }
            Text("New packs install in an Expansions folder at the cache location. Inside the disk image the wallpaper extension can play them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if expansionsAtLocation, externalImageState != .off, !isImageAttached {
                Text("Packs there are hidden until the image is attached.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(.leading, 20)
    }

    private func setExpansionsAtLocation(_ enabled: Bool) {
        guard let root = Cache.expansionsRootCandidate else {
            PrefsCache.expansionsAtCacheLocation = enabled
            return
        }
        // Candidates before the prefs change: disabling drops the root
        // from the scan, so packs living there must be listed now.
        let packs = enabled ? installedPacks(inRoot: "") : installedPacks(inRoot: root)
        let destination = enabled ? root : Cache.defaultSourcesRoot
        PrefsCache.expansionsAtCacheLocation = enabled
        if enabled {
            ExternalCacheImage.ensureExpansionsRoot()
        }
        ExternalCacheImage.refreshConsumers(reason: enabled ? "settings: packs at cache location" : "settings: packs back to default root")
        offerToMove(packs, to: destination)
    }

    /// Installed Expansion packs whose folder lives under `root` ("" =
    /// the default Sources root). Live Feeds parses as non-cacheable but
    /// is NOT an expansion pack (default-root managed, excluded by name
    /// like elsewhere); My Videos is `.local`.
    private func installedPacks(inRoot root: String) -> [Source] {
        SourceList.list.filter {
            $0.isExpansionPack && $0.rootPath == root && $0.isCached()
        }
    }

    /// Present the move sheet for `sources` (sizes computed off-main).
    private func offerToMove(_ sources: [Source], to destination: String) {
        guard !sources.isEmpty else {
            runPendingDetach()
            return
        }
        let entries = sources.map { (name: $0.name, path: $0.folderPath) }
        Task.detached(priority: .utility) {
            let packs = entries.map {
                MovablePack(name: $0.name, sizeGB: Cache.getDirectorySize(directory: $0.path), fromPath: $0.path)
            }
            await MainActor.run {
                packsMovedCount = 0
                movablePacksOffer = MovablePacksOffer(packs: packs, destination: destination)
            }
        }
    }

    private func movePacks(_ offer: MovablePacksOffer) {
        let destination = offer.destination
        guard !destination.isEmpty else { return }
        isMovingPacks = true
        packsMovedCount = 0

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try? fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
            for pack in offer.packs {
                let target = (destination as NSString).appendingPathComponent(pack.name)
                do {
                    // Cross-volume moveItem copies then removes.
                    try fm.moveItem(atPath: pack.fromPath, toPath: target)
                } catch {
                    debugLog("Failed to move pack \(pack.name): \(error.localizedDescription)")
                }
                await MainActor.run { packsMovedCount += 1 }
            }
            await MainActor.run {
                isMovingPacks = false
                movablePacksOffer = nil
                ExternalCacheImage.refreshConsumers(reason: "settings: packs moved")
                runPendingDetach()
                Task { await loadSizes() }
            }
        }
    }

    private func runPendingDetach() {
        guard let reason = pendingDetachReason else { return }
        pendingDetachReason = nil
        detachInBackground(reason: reason)
    }

    // MARK: - External cache image

    private var isImageAttached: Bool {
        if case .attached = externalImageState { return true }
        return false
    }

    private var externalStatusText: String {
        switch externalImageState {
        case .off: return ""
        case .attached(let device): return "Attached at \(Cache.externalCacheMountPoint) (\(device))"
        case .detached: return "Not attached"
        case .backingVolumeMissing: return "Drive not connected"
        case .failed: return "Attach failed"
        }
    }

    private var externalStatusColor: Color {
        switch externalImageState {
        case .attached: return .green
        case .detached, .backingVolumeMissing: return .orange
        case .failed: return .red
        case .off: return .secondary
        }
    }

    /// An image in a home folder sits on the boot volume: there is no drive
    /// to eject. Path-based on purpose — asking the volume would wake a
    /// sleeping external drive on every redraw.
    private var imageIsOnRemovableVolume: Bool {
        (PrefsCache.externalCacheImagePath ?? "").hasPrefix("/Volumes/")
    }

    private var externalImageStatusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(externalStatusColor)
                    .frame(width: 8, height: 8)
                Text(externalStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Reconnect") {
                    externalError = nil
                    isMigrating = true
                    migrationFilesTotal = 0
                    externalStepText = "Attaching…"
                    ExternalCacheImage.shared.attachIfNeeded(reason: "user")
                }
                .disabled(isImageAttached || externalImageState == .backingVolumeMissing || isMigrating)
                if imageIsOnRemovableVolume {
                    Button("Eject Drive") {
                        ejectExternalDrive()
                    }
                    .disabled(!isImageAttached || isMigrating)
                }
            }
            Text("Videos (and Expansion packs, if enabled below) are kept in a disk image in the cache folder (\(ExternalCacheImage.bundleName)) so the wallpaper extension can read them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let externalError {
                Label(externalError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    /// A plain custom folder outside `/Users/Shared`, with no image yet.
    /// Companion reads it, while the wallpaper extension cannot. Same offer
    /// as the launch prompt, from Settings.
    private func legacyExternalFolderRow(_ folder: String) -> some View {
        let mounted = FileManager.default.fileExists(atPath: folder)
        // On the boot volume the videos can simply move to the default
        // location (a rename) — the recommended way out there.
        let canMoveToDefault = !LegacyExternalCacheMigration.isOnExternalVolume(folder)
        return VStack(alignment: .leading, spacing: 6) {
            Label("This folder is on an external drive", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.orange)
            Text("Aerial 4.1 keeps external caches in a disk image so the wallpaper extension can play them. Nothing plays on the desktop until this folder is converted. The videos in it are moved into the image; nothing is deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if mounted {
                    if canMoveToDefault {
                        Button("Move to Default…") {
                            moveLegacyFolderToDefault(folder)
                        }
                        .disabled(isMigrating)
                    }
                    Button("Convert Now…") {
                        confirmAndApply(newPath: folder)
                    }
                    .disabled(isMigrating)
                } else {
                    Text(folder.hasPrefix("/Volumes/")
                         ? "Drive not connected — plug it in to convert."
                         : "Folder not found — choose a folder again or use the default location.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.08))
        )
    }

    /// The way out for a legacy folder on the boot volume: videos and packs
    /// move to the default location (a rename on the same disk) and the
    /// custom location is switched off. Same model call as the launch
    /// prompt's card; `loadSettings` afterwards resets the toggle, the path
    /// and the Time Machine checkbox (the exclusion is carried over).
    private func moveLegacyFolderToDefault(_ folder: String) {
        let inventory = LegacyExternalCacheMigration.inventory(folder: folder)
        let packs = ExternalCacheImage.siblingPacks(inFolder: folder).count
        let videos = "\(inventory.count) video\(inventory.count == 1 ? "" : "s") (\(inventory.formattedBytes))"
        let packsText = packs > 0
            ? " and \(packs) Expansion pack\(packs == 1 ? "" : "s") to \(Cache.defaultSourcesRoot)"
            : ""
        let alert = NSAlert()
        alert.messageText = "Move the videos in this folder to the default location?"
        alert.informativeText = "Aerial moves the \(videos) in it to \(Cache.defaultCachePath)\(packsText), where the wallpaper extension can play them, and switches the custom cache location off. Same disk, so the move takes seconds. Nothing is deleted."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        externalError = nil
        isMigrating = true
        migrationFilesDone = 0
        migrationFilesTotal = 0
        externalStepText = "Moving videos and packs…"
        Task { @MainActor in
            let outcome = await LegacyExternalCacheMigration.moveToDefaultLocation(folder: folder) { step in
                if case .moving(let done, let total) = step {
                    migrationFilesDone = done
                    migrationFilesTotal = total
                }
            }
            migrationFilesDone = 0
            migrationFilesTotal = 0
            externalStepText = ""
            isMigrating = false
            if outcome.failed > 0 {
                externalError = "\(outcome.failed) video(s) or pack(s) could not be moved to the default cache and stay in \(folder) — see the log."
            }
            loadSettings()
            await loadSizes()
        }
    }

    /// External drive chosen: create the image there (if absent), attach
    /// it, and only then switch the prefs. An optional migration moves the
    /// current cache's videos INTO the image afterwards.
    private func applyExternalCache(folder: String, migrateFrom oldPath: String?) {
        externalError = nil
        isMigrating = true
        migrationFilesDone = 0
        migrationFilesTotal = 0
        externalStepText = "Creating disk image…"
        let switchingImages = Cache.isExternalImageMode
        let wantsTimeMachineExclusion = excludeTimeMachine
        let oldPacksRoot = PrefsCache.expansionsAtCacheLocation ? Cache.expansionsRootCandidate : nil

        Task.detached {
            do {
                if switchingImages {
                    // One mount point, one image: release the current one first.
                    await ExternalCacheImage.shared.detachIfAttached(reason: "settings: switching drive", mode: .escalate)
                }
                let bundle = try ExternalCacheImage.shared.create(inFolder: folder)
                await MainActor.run { externalStepText = "Attaching…" }
                let device = try ExternalCacheImage.shared.attachCandidate(image: bundle)
                await MainActor.run {
                    ExternalCacheImage.shared.adopt(image: bundle, device: device)
                }
                if wantsTimeMachineExclusion {
                    // tmutil takes ~11 s on a sparsebundle — never on main.
                    TimeMachine.exclude()
                }
                // Videos already sitting in the chosen folder (a 4.0-style
                // cache, or leftovers from an earlier "Start fresh" / toggle
                // round trip) always come into the image — whatever route
                // the user took to get here.
                await MainActor.run {
                    externalStepText = "Moving videos and packs…"
                    migrationFilesDone = 0
                    migrationFilesTotal = 0
                }
                let adopted = await ExternalCacheImage.shared.adoptSiblingVideos(inFolder: folder) { done, total in
                    // Delivered on main by the helper; hop explicitly so
                    // the state writes are provably main-actor.
                    Task { @MainActor in
                        migrationFilesDone = done
                        migrationFilesTotal = total
                    }
                }
                if adopted.failed > 0 {
                    await MainActor.run {
                        externalError = "\(adopted.failed) video(s) or pack(s) could not be moved into the disk image — see the log."
                    }
                }
                await MainActor.run {
                    externalImageState = ExternalCacheImage.shared.state
                    externalImageFolder = folder
                    customCachePath = folder
                    useCustomLocation = true
                    migrationFilesDone = 0
                    migrationFilesTotal = 0
                    if let oldPath, oldPath != folder {
                        externalStepText = "Moving videos and packs…"
                        let packs = oldPacksRoot.map { (from: $0, to: Cache.externalCacheMountPoint.appending("/Expansions")) }
                        migrateVideos(from: oldPath, to: Cache.externalCacheMountPoint.appending("/Cache"), packs: packs) {
                            externalStepText = ""
                            ExternalCacheImage.refreshConsumers(reason: "settings: migration into image done")
                        }
                    } else {
                        externalStepText = ""
                        isMigrating = false
                        ExternalCacheImage.refreshConsumers(reason: "settings: external cache")
                    }
                }
            } catch {
                let message = error.localizedDescription
                errorLog("💽 external cache setup failed for \(folder): \(message)")
                await MainActor.run {
                    externalError = message
                    externalStepText = ""
                    isMigrating = false
                }
            }
        }
    }

    /// Detach the image, then ask macOS to eject the drive that holds it.
    /// Both steps block for seconds — off-main with the busy indicator up.
    private func ejectExternalDrive() {
        guard let image = PrefsCache.externalCacheImagePath, !image.isEmpty else { return }
        externalError = nil
        isMigrating = true
        migrationFilesTotal = 0
        externalStepText = "Ejecting…"
        Task {
            let detached = await ExternalCacheImage.shared.detachIfAttached(reason: "user eject", mode: .escalate)
            var ejectError: String?
            if detached, let volume = try? URL(fileURLWithPath: image).resourceValues(forKeys: [.volumeURLKey]).volume {
                ejectError = await Task.detached {
                    do {
                        try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                        return nil
                    } catch {
                        return "Could not eject the drive: \(error.localizedDescription)"
                    }
                }.value
            }
            externalImageState = ExternalCacheImage.shared.state
            externalError = ejectError
            externalStepText = ""
            isMigrating = false
        }
    }

    /// Move the `.mov` files of the old cache into the new one and, when
    /// `packs` is given, every pack folder from the old Expansions root
    /// into the new one (one progress counter for both).
    private func migrateVideos(from oldPath: String, to newPath: String,
                               packs: (from: String, to: String)? = nil,
                               completion: (() -> Void)? = nil) {
        isMigrating = true
        migrationFilesDone = 0
        migrationFilesTotal = 0

        Task.detached {
            let fm = FileManager.default
            var jobs: [(src: String, dst: String)] = []
            if let contents = try? fm.contentsOfDirectory(atPath: oldPath) {
                for file in contents where file.hasSuffix(".mov") {
                    jobs.append((src: (oldPath as NSString).appendingPathComponent(file),
                                 dst: (newPath as NSString).appendingPathComponent(file)))
                }
            } else {
                debugLog("Failed to enumerate old cache at \(oldPath)")
            }
            if let packs, let folders = try? fm.contentsOfDirectory(atPath: packs.from) {
                try? fm.createDirectory(atPath: packs.to, withIntermediateDirectories: true)
                for folder in folders where !folder.hasPrefix(".") {
                    jobs.append((src: (packs.from as NSString).appendingPathComponent(folder),
                                 dst: (packs.to as NSString).appendingPathComponent(folder)))
                }
            }
            try? fm.createDirectory(atPath: newPath, withIntermediateDirectories: true)

            await MainActor.run {
                migrationFilesTotal = jobs.count
            }

            for job in jobs {
                do {
                    try fm.moveItem(atPath: job.src, toPath: job.dst)
                } catch {
                    debugLog("Failed to move \(job.src): \(error)")
                }
                await MainActor.run {
                    migrationFilesDone += 1
                }
            }

            await MainActor.run {
                isMigrating = false
                completion?()
            }
            await loadSizes()
        }
    }


    // MARK: - Downloads

    private var downloadsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Automatically download videos", isOn: $enableManagement)
                    .font(.system(size: 14))
                    .onChange(of: enableManagement) { newValue in
                        PrefsCache.enableManagement = newValue
                    }

                VStack(alignment: .leading, spacing: 16) {
                    Divider()

                    Toggle("Unlimited cache", isOn: $unlimitedCache)
                        .font(.system(size: 14))
                        .onChange(of: unlimitedCache) { newValue in
                            PrefsCache.unlimitedCache = newValue
                        }

                    if !unlimitedCache {
                        HStack {
                            Text("Cache limit")
                                .font(.system(size: 14))
                            Spacer()
                            Slider(value: $cacheLimit, in: 5...150, step: 5)
                                .frame(width: 360)
                                .onChange(of: cacheLimit) { newValue in
                                    PrefsCache.cacheLimit = newValue
                                }
                            Text("\(Int(cacheLimit)) GB")
                                .font(.system(size: 14))
                                .frame(width: 50, alignment: .trailing)
                        }
                    }

                    HStack {
                        Text("Replace videos")
                            .font(.system(size: 14))
                        Spacer()
                        Picker("", selection: $cachePeriodicity) {
                            Text("Daily").tag(CachePeriodicity.daily)
                            Text("Weekly").tag(CachePeriodicity.weekly)
                            Text("Monthly").tag(CachePeriodicity.monthly)
                            Text("Never").tag(CachePeriodicity.never)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 220, alignment: .trailing)
                        .onChange(of: cachePeriodicity) { newValue in
                            PrefsCache.cachePeriodicity = newValue
                        }
                    }

                }
                .disabled(!enableManagement)
                .opacity(enableManagement ? 1 : 0.5)

                Divider()

                Toggle("Show a Dock badge while downloading", isOn: $dockDownloadBadge)
                    .font(.system(size: 14))
                    .onChange(of: dockDownloadBadge) { newValue in
                        Preferences.dockDownloadBadge = newValue
                        AppPresentationController.shared.refreshDockBadge()
                    }

                Text("When Aerial is in the Dock, its icon shows the number of videos left to download. In the menu bar, a small dot on the Aerial icon plays the same role.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(12)
        } label: {
            Label("Downloads", systemImage: "arrow.down.circle")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Only download on trusted Wi-Fi networks", isOn: $restrictOnWiFi)
                    .font(.system(size: 14))
                    .onChange(of: restrictOnWiFi) { newValue in
                        PrefsCache.restrictOnWiFi = newValue
                        if newValue {
                            // Ensure Location is requested so macOS
                            // un-gates `CWInterface.ssid()`. The first
                            // call here is what surfaces the system
                            // prompt — without it the user has no way
                            // to grant access from inside Aerial.
                            LocationProvider.shared.reevaluate()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                currentSSID = Cache.ssid
                                locationAuth = LocationProvider.shared.authorizationStatus
                            }
                        }
                    }

                if restrictOnWiFi {
                    Divider()

                    let needsLocationGrant = currentSSID.isEmpty
                        && (locationAuth == .notDetermined
                            || locationAuth == .denied
                            || locationAuth == .restricted)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(needsLocationGrant ? Color.orange : (currentSSID.isEmpty ? Color.red : (allowedNetworks.contains(currentSSID) ? Color.green : Color.orange)))
                            .frame(width: 8, height: 8)

                        if needsLocationGrant {
                            Text("Wi-Fi name needs Location permission")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        } else if currentSSID.isEmpty {
                            Text("Not connected to Wi-Fi")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        } else {
                            Text("Connected to: \(currentSSID)")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    }

                    if needsLocationGrant {
                        // macOS gates `CWInterface.ssid()` on Location
                        // auth; without it the panel can't tell which
                        // network the user is on. Open the right pane
                        // directly so the user has a one-click path.
                        Button("Open Location Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }

                    if !allowedNetworks.isEmpty {
                        Text("Trusted networks: \(allowedNetworks.joined(separator: ", "))")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    } else {
                        Text("No trusted networks configured")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button("Trust current network") {
                            trustCurrentNetwork()
                        }
                        .disabled(currentSSID.isEmpty || allowedNetworks.contains(currentSSID))

                        Button("Reset list") {
                            allowedNetworks = []
                            PrefsCache.allowedNetworks = []
                        }
                        .disabled(allowedNetworks.isEmpty)
                    }
                }
            }
            .padding(12)
        } label: {
            Label("Network", systemImage: "wifi")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Exclude cache from Time Machine backups", isOn: $excludeTimeMachine)
                    .font(.system(size: 14))
                    .disabled(timeMachineOnDisk == nil)
                    .onChange(of: excludeTimeMachine) { newValue in
                        // Only a user flip: the programmatic load sets both
                        // values together so newValue == known here.
                        guard let known = timeMachineOnDisk, newValue != known else { return }
                        timeMachineOnDisk = newValue
                        Task.detached {
                            if newValue {
                                TimeMachine.exclude()
                            } else {
                                TimeMachine.reinclude()
                            }
                        }
                    }
            }
            .padding(12)
        } label: {
            Label("Storage", systemImage: "externaldrive")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    // MARK: - Private Methods

    private func loadSettings() {
        enableManagement = PrefsCache.enableManagement
        // `unlimitedCache` is now its own boolean preference; no more
        // overloading the cacheLimit GB value as a sentinel. The Codable
        // migration in ScreensaverSettings.init(from:) handles users
        // upgrading from the old `cacheLimit = 500` representation.
        unlimitedCache = PrefsCache.unlimitedCache
        cacheLimit = PrefsCache.cacheLimit
        cachePeriodicity = PrefsCache.cachePeriodicity
        dockDownloadBadge = Preferences.dockDownloadBadge
        restrictOnWiFi = PrefsCache.restrictOnWiFi
        allowedNetworks = PrefsCache.allowedNetworks
        currentSSID = Cache.ssid
        locationAuth = LocationProvider.shared.authorizationStatus
        // tmutil spawns are slow (isexcluded ~0.1 s, addexclusion ~11 s on a
        // sparsebundle) — read the state off-main and set both values at
        // once so the toggle's onChange stays quiet.
        Task.detached {
            let excluded = TimeMachine.isExcluded()
            await MainActor.run {
                timeMachineOnDisk = excluded
                excludeTimeMachine = excluded
            }
        }
        useCustomLocation = PrefsCache.overrideCache
        customCachePath = PrefsCache.cachePath ?? ""
        externalImageState = ExternalCacheImage.shared.state
        externalImageFolder = ((PrefsCache.externalCacheImagePath ?? "") as NSString).deletingLastPathComponent
        if Cache.isExternalImageMode {
            // Show the drive folder the user chose, not the mount point.
            customCachePath = externalImageFolder
        }
        expansionsAtLocation = PrefsCache.expansionsAtCacheLocation
    }

    private func loadSizes() async {
        // Off-main: `size()` walks the cache folder and `packsSize()`
        // re-parses every source manifest (same split as the dashboard card).
        let (cs, ps, ss) = await Task.detached(priority: .utility) {
            (Cache.size(), Cache.packsSize(), Cache.sizeString())
        }.value
        await MainActor.run {
            cacheSize = cs
            packsSize = ps
            cacheSizeString = ss
            sizesLoaded = true
        }
    }

    private func trustCurrentNetwork() {
        guard !currentSSID.isEmpty, !allowedNetworks.contains(currentSSID) else { return }
        allowedNetworks.append(currentSSID)
        PrefsCache.allowedNetworks = allowedNetworks
    }
}

// MARK: - Move Expansions Sheet

/// An installed non-cacheable pack eligible to move between the default
/// Sources root and the Expansions folder at the cache location.
struct MovablePack: Identifiable {
    let id = UUID()
    let name: String
    let sizeGB: Double
    let fromPath: String
}

/// Sheet payload — item-based presentation so the sheet always renders
/// with the packs it was presented for.
struct MovablePacksOffer: Identifiable {
    let id = UUID()
    let packs: [MovablePack]
    /// Folder the packs move INTO (the derived Expansions root, or the
    /// default Sources root when moving back).
    let destination: String
}

/// Offers to relocate installed expansion packs to the cache location
/// (or back to the default root). Same design language as `InstallThankYouView`
/// (heart header, 500-wide sheet).
private struct MoveExpansionsSheet: View {
    let packs: [MovablePack]
    let destination: String
    let isMoving: Bool
    let movedCount: Int
    let onMove: () -> Void
    let onManual: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.pink)
                Text("Your expansions")
                    .font(.system(size: 28, weight: .bold))
            }

            Text(packs.count == 1
                ? "You have 1 pack that can be moved to the new location."
                : "You have \(packs.count) packs that can be moved to the new location.")
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(packs) { pack in
                    HStack {
                        Image(systemName: "shippingbox.fill")
                            .foregroundColor(.secondary)
                        Text(pack.name)
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text(String(format: "%.1f GB", pack.sizeGB))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            Text(destination)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if isMoving {
                HStack(spacing: 8) {
                    ProgressView(value: Double(movedCount), total: max(1, Double(packs.count)))
                        .frame(maxWidth: .infinity)
                    Text("\(movedCount)/\(packs.count)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("I'll move them manually") {
                    onManual()
                }
                .disabled(isMoving)
                Button("Move Packs") {
                    onMove()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isMoving)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

// MARK: - Preview

struct CacheSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        CacheSettingsPanel()
            .frame(width: 500, height: 700)
    }
}
