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

    // Downloads
    @State private var enableManagement = true
    @State private var unlimitedCache = false
    @State private var cacheLimit: Double = 5
    @State private var cachePeriodicity: CachePeriodicity = .never
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

    // Location
    @State private var useCustomLocation = false
    @State private var customCachePath: String = ""
    @State private var isMigrating = false
    @State private var migrationFilesDone = 0
    @State private var migrationFilesTotal = 0

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
    }

    // MARK: - Disk Usage

    private var diskUsageSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if sizesLoaded {
                    diskUsageBar
                    diskUsageLegend
                    Text("Your videos take \(cacheSizeString) of disk space")
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

    private var diskUsageBar: some View {
        let limit = unlimitedCache ? 0.0 : cacheLimit
        let total = unlimitedCache ? (cacheSize + packsSize) : max(limit, cacheSize + packsSize)
        let freeSpace = unlimitedCache ? 0.0 : max(0, limit - cacheSize - packsSize)

        return GeometryReader { geo in
            HStack(spacing: 2) {
                if cacheSize > 0, total > 0 {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.indigo)
                        .frame(width: max(4, geo.size.width * cacheSize / total))
                }
                if packsSize > 0.01, total > 0 {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.mint)
                        .frame(width: max(4, geo.size.width * packsSize / total))
                }
                if freeSpace > 0.01, total > 0 {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: max(4, geo.size.width * freeSpace / total))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 20)
    }

    private var diskUsageLegend: some View {
        HStack(spacing: 16) {
            legendItem(color: .indigo, label: "Cache: \(String(format: "%.1f", cacheSize)) GB")
            if packsSize > 0.01 {
                legendItem(color: .mint, label: "Packs: \(String(format: "%.1f", packsSize)) GB")
            }
            if !unlimitedCache {
                let freeSpace = max(0, cacheLimit - cacheSize - packsSize)
                legendItem(color: .gray.opacity(0.3), label: "Free: \(String(format: "%.1f", freeSpace)) GB")
            }
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

                Toggle("Use custom location", isOn: $useCustomLocation)
                    .font(.system(size: 14))
                    .onChange(of: useCustomLocation) { newValue in
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
                }

                if isMigrating {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(migrationFilesDone), total: max(1, Double(migrationFilesTotal)))
                            .frame(maxWidth: .infinity)
                        Text("\(migrationFilesDone)/\(migrationFilesTotal)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)
        } label: {
            Label("Location", systemImage: "folder")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    private func pickCacheFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.begin { result in
            guard result == .OK, let url = panel.urls.first else { return }
            confirmAndApply(newPath: url.path)
        }
    }

    private func confirmAndApply(newPath: String) {
        let oldPath = Cache.path
        // Don't do anything if it's the same path
        guard newPath != oldPath else { return }

        let alert = NSAlert()
        alert.messageText = "Change cache location?"
        alert.informativeText = "What would you like to do with videos in the current cache folder?"
        alert.addButton(withTitle: "Move existing videos")
        alert.addButton(withTitle: "Start fresh (keep old)")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            applyCachePath(newPath)
            migrateVideos(from: oldPath, to: newPath)
        case .alertSecondButtonReturn:
            applyCachePath(newPath)
        default:
            break
        }
    }

    private func applyCachePath(_ newPath: String) {
        PrefsCache.cachePath = newPath
        PrefsCache.overrideCache = true
        Cache.invalidateCachePath()
        customCachePath = newPath
        Task {
            await loadSizes()
        }
    }

    private func resetToDefaultLocation() {
        PrefsCache.overrideCache = false
        PrefsCache.cachePath = nil
        Cache.invalidateCachePath()
        customCachePath = ""
        Task {
            await loadSizes()
        }
    }

    private func migrateVideos(from oldPath: String, to newPath: String) {
        isMigrating = true
        migrationFilesDone = 0
        migrationFilesTotal = 0

        Task.detached {
            let fm = FileManager.default
            do {
                let contents = try fm.contentsOfDirectory(atPath: oldPath)
                let movFiles = contents.filter { $0.hasSuffix(".mov") }

                await MainActor.run {
                    migrationFilesTotal = movFiles.count
                }

                for file in movFiles {
                    let src = (oldPath as NSString).appendingPathComponent(file)
                    let dst = (newPath as NSString).appendingPathComponent(file)
                    do {
                        try fm.moveItem(atPath: src, toPath: dst)
                    } catch {
                        debugLog("Failed to move \(file): \(error)")
                    }
                    await MainActor.run {
                        migrationFilesDone += 1
                    }
                }
            } catch {
                debugLog("Failed to enumerate old cache: \(error)")
            }

            await MainActor.run {
                isMigrating = false
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
                            if newValue {
                                // Sentinel value treated as "unlimited" in UI. The eviction
                                // code in Cache.swift still enforces it as a real GB cap, so
                                // pick a number a user realistically can't fill up.
                                PrefsCache.cacheLimit = 500
                            } else {
                                PrefsCache.cacheLimit = cacheLimit
                            }
                        }

                    if !unlimitedCache {
                        HStack {
                            Text("Cache limit")
                                .font(.system(size: 14))
                            Spacer()
                            Slider(value: $cacheLimit, in: 5...150, step: 5)
                                .frame(width: 360)
                                .onChange(of: cacheLimit) { newValue in
                                    if !unlimitedCache {
                                        PrefsCache.cacheLimit = newValue
                                    }
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
                    .onChange(of: excludeTimeMachine) { newValue in
                        if newValue {
                            TimeMachine.exclude()
                        } else {
                            TimeMachine.reinclude()
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
        let limit = PrefsCache.cacheLimit
        // Any stored value above the slider max (60 GB) is treated as
        // "unlimited" — catches both the current sentinel (500) and the
        // legacy one (101) so users on older builds keep their toggle.
        unlimitedCache = limit > 60
        cacheLimit = unlimitedCache ? 60 : limit
        cachePeriodicity = PrefsCache.cachePeriodicity
        restrictOnWiFi = PrefsCache.restrictOnWiFi
        allowedNetworks = PrefsCache.allowedNetworks
        currentSSID = Cache.ssid
        locationAuth = LocationProvider.shared.authorizationStatus
        excludeTimeMachine = TimeMachine.isExcluded()
        useCustomLocation = PrefsCache.overrideCache
        customCachePath = PrefsCache.cachePath ?? ""
    }

    private func loadSizes() async {
        let cs = Cache.size()
        let ps = Cache.packsSize()
        let ss = Cache.sizeString()
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

// MARK: - Preview

struct CacheSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        CacheSettingsPanel()
            .frame(width: 500, height: 700)
    }
}
