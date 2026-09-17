//
//  DiagnosticsExporter.swift
//  Aerial
//
//  One-click diagnostics bundle for bug reports: zips the shared logs
//  (including rolled .1/.2 generations), the /Users/Shared/Aerial
//  config sidecars, recent crash/resource reports for our processes and
//  WallpaperAgent from DiagnosticReports, a generated system-info
//  report (versions, displays, pluginkit registrations, power state)
//  and a live CGWindowList dump. Everything a triage session usually
//  has to ask a tester to fish out by hand, in one file.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

enum DiagnosticsExporter {

    private struct ExportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Config sidecars worth bundling — everything the app and the
    /// wallpaper extension coordinate through. All under baseDirectory.
    private static let sidecarFiles = [
        "companion.json",
        "screensaver.json",
        "overlay-config.json",
        "playlists.json",
        "playlist-progress.json",
        "playback-handoff.json",
        "wallpaper-control.json",
        "wallpaper-status.json",
        "now-playing.json",
    ]

    // MARK: - Entry point

    /// Ask where to save, then assemble and zip off-main. Reveals the
    /// archive in Finder when done.
    @MainActor
    static func exportInteractively() {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.message = "Saves a zip of Aerial's logs and settings to attach to a bug report."
        panel.prompt = "Export"
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = defaultArchiveName()
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        // The window dump enumerates on whatever thread calls it; grab
        // it here so the report reflects the moment the user clicked.
        let windowDump = WallpaperWindowDump.capture()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try export(to: destination, windowDump: windowDump)
                debugLog("🩺 Diagnostics exported to \(destination.path)")
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch {
                errorLog("🩺 Diagnostics export failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    Helpers.showErrorAlert(
                        question: "Diagnostics export failed",
                        text: error.localizedDescription
                    )
                }
            }
        }
    }

    // MARK: - Bundle assembly

    private static func export(to destination: URL, windowDump: [String]) throws {
        let fm = FileManager.default
        let stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aerial-diagnostics-\(UUID().uuidString)")
        // Folder name inside the zip (--keepParent below).
        let bundleDir = stagingRoot.appendingPathComponent(
            destination.deletingPathExtension().lastPathComponent
        )
        try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        let base = URL(fileURLWithPath: AerialPaths.baseDirectory)

        // Logs — the app and extension logs are the core of the bundle.
        copyIfPresent(from: URL(fileURLWithPath: AerialPaths.logsPath()),
                      to: bundleDir.appendingPathComponent("Logs"))

        // Config sidecars + user playlists.
        let configDir = bundleDir.appendingPathComponent("Config")
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        for name in sidecarFiles {
            copyIfPresent(from: base.appendingPathComponent(name),
                          to: configDir.appendingPathComponent(name))
        }
        copyIfPresent(from: base.appendingPathComponent("Playlists"),
                      to: configDir.appendingPathComponent("Playlists"))

        // The wallpaper store: which slots hold Aerial and with what
        // option values decides how WallpaperAgent presents us (the
        // 2026-09-17 frozen-saver-start report hinged on it). Companion is
        // unsandboxed, so a plain copy works.
        copyIfPresent(from: WallpaperStoreSummary.storeURL,
                      to: configDir.appendingPathComponent("wallpaper-store-Index.plist"))

        // Crash / resource reports (.ips/.diag) for our processes and
        // WallpaperAgent — the one artifact testers can never find on
        // their own, and the 2026-07 churn triage had to ask for by
        // hand (and got none).
        copyCrashReports(to: bundleDir.appendingPathComponent("CrashReports"))

        // Generated reports.
        try systemInfoReport().write(
            to: bundleDir.appendingPathComponent("system-info.txt"),
            atomically: true, encoding: .utf8
        )
        try (["Window dump (wallpaper/desktop-band) at export time:", ""] + windowDump)
            .joined(separator: "\n")
            .write(to: bundleDir.appendingPathComponent("window-dump.txt"),
                   atomically: true, encoding: .utf8)

        // Zip. ditto preserves structure and is always present.
        try? fm.removeItem(at: destination)
        let result = Helpers.shell(
            launchPath: "/usr/bin/ditto",
            arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent",
                        bundleDir.path, destination.path]
        )
        guard fm.fileExists(atPath: destination.path) else {
            throw ExportError(message: "Could not create the archive. \(result ?? "")")
        }
    }

    /// Copy, silently skipping sources that don't exist (fresh installs
    /// won't have every sidecar).
    private static func copyIfPresent(from source: URL, to target: URL) {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.copyItem(at: source, to: target)
    }

    /// Process-name prefixes worth collecting from DiagnosticReports:
    /// our app, our appex, and the agent that hosts it (an agent crash
    /// explains a wallpaper reset just as well as ours would).
    private static let crashReportPrefixes = [
        "Aerial",                       // Aerial app + Aerial4WallpaperExtension
        "WallpaperAgent",
    ]

    /// How far back to collect reports. Testers usually export within
    /// days of an incident; a fortnight bounds the bundle size.
    private static let crashReportMaxAge: TimeInterval = 14 * 86400

    /// Gather recent .ips/.diag/.crash reports for interesting processes
    /// from the user and system DiagnosticReports folders. System-level
    /// reads may fail without admin rights — skipped silently, best
    /// effort by design.
    private static func copyCrashReports(to target: URL) {
        let fm = FileManager.default
        let sources = [
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports"),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
        ]
        let cutoff = Date().addingTimeInterval(-crashReportMaxAge)
        var copied = 0
        for dir in sources {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for entry in entries {
                let name = entry.lastPathComponent
                guard ["ips", "diag", "crash"].contains(entry.pathExtension.lowercased()),
                      crashReportPrefixes.contains(where: { name.hasPrefix($0) }),
                      let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                          .contentModificationDate,
                      modified > cutoff
                else { continue }
                if copied == 0 {
                    try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                }
                try? fm.copyItem(at: entry, to: target.appendingPathComponent(name))
                copied += 1
            }
        }
        debugLog("🩺 bundled \(copied) crash report(s) from DiagnosticReports")
    }

    // MARK: - Reports

    private static func movCount(at path: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { $0.hasSuffix(".mov") }.count
    }

    private static func systemInfoReport() -> String {
        var lines: [String] = []
        let info = ProcessInfo.processInfo
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        lines.append("Aerial diagnostics — \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("== App ==")
        lines.append("Version: \(Helpers.version) (build \(build))")
        lines.append("macOS: \(info.operatingSystemVersionString)")
        lines.append("Hardware: \(hardwareModel())")
        lines.append("")

        lines.append("== Displays ==")
        for screen in NSScreen.screens {
            let did = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            lines.append("\(screen.localizedName): frame=\(screen.frame) scale=\(screen.backingScaleFactor)"
                + " did=\(did.map(String.init) ?? "?")")
        }
        lines.append("")

        lines.append("== Power ==")
        lines.append("Thermal state: \(thermalStateName(info.thermalState))")
        lines.append("Low Power Mode: \(info.isLowPowerModeEnabled)")
        if Battery.hasBattery() {
            lines.append("Battery: \(Battery.getRemainingPercent())%, unplugged=\(Battery.isUnplugged())")
        } else {
            lines.append("Battery: none")
        }
        lines.append("")

        // Cache location — the first thing to read in a "wallpaper says
        // 'No videos found' but the library shows them cached" bundle: a
        // 4.0-style external folder is readable by Companion, never by the
        // extension.
        lines.append("== Cache ==")
        let cachePath = Cache.path
        let mode: String
        switch Cache.locationKind {
        case .internalFolder:
            mode = "internal"
        case .customFolder:
            mode = "custom folder"
        case .legacyExternalFolder:
            mode = "LEGACY external folder (4.0 layout — the extension cannot read it; conversion pending)"
        case .externalImage(let image):
            mode = "external disk image \(image), state \(ExternalCacheImage.shared.state)"
        }
        lines.append("Mode: \(mode)")
        // The folder holding the image (or the 4.0 folder): a network
        // share without full-sync support can never hold a working image.
        let hostFolder: String?
        switch Cache.locationKind {
        case .externalImage(let image): hostFolder = (image as NSString).deletingLastPathComponent
        case .legacyExternalFolder(let folder): hostFolder = folder
        case .internalFolder, .customFolder: hostFolder = nil
        }
        if let hostFolder {
            let mounted = FileManager.default.fileExists(atPath: hostFolder)
            var volume = "Backing volume: \(mounted ? ExternalCacheImage.volumeDescription(hostFolder) : "not mounted")"
            if mounted, ExternalCacheImage.volumeIsNetwork(hostFolder) {
                volume += ", full sync: \(ExternalCacheImage.supportsFullSync(folder: hostFolder) ? "yes" : "NO — cannot host a disk image")"
            }
            lines.append(volume)
        }
        lines.append("Path: \(cachePath)")
        lines.append("Available: \(Cache.isAvailable), exists: \(FileManager.default.fileExists(atPath: cachePath)),"
            + " readable by the extension: \(cachePath.hasPrefix("/Users/Shared/"))")
        lines.append("Videos at path: \(movCount(at: cachePath))")
        if let legacy = Cache.legacyExternalFolderPath {
            lines.append("Legacy folder: \(legacy) mounted=\(FileManager.default.fileExists(atPath: legacy)) videos=\(movCount(at: legacy))")
        }
        lines.append("Expansion packs at cache location: \(PrefsCache.expansionsAtCacheLocation)")
        lines.append("")

        // Stale-extension verdict — the first thing to read in a "default
        // wallpaper / black screen after update" bundle.
        lines.append("== Wallpaper extension ==")
        let bundled = WallpaperExtensionHealth.bundledIdentity
        lines.append("Bundled: \(bundled)")
        if let status = JSONPreferencesStore.shared.read(WallpaperStatusState.self, from: WallpaperStatusState.fileURL) {
            let age = Int(Date().timeIntervalSince(status.lastSeen))
            let alive = WallpaperExtensionHealth.isAlive(pid: status.pid)
            let hosted = WallpaperExtensionHealth.hostedExecutablePath(pid: status.pid)
            let outside = hosted.map { WallpaperExtensionHealth.isInsideThisApp(path: $0) ? "" : "  (OUTSIDE this app bundle)" } ?? ""
            lines.append("Running: \(status.identity) pid=\(status.pid) alive=\(alive) lastSeen=\(age)s ago")
            lines.append("Hosted at: \(hosted ?? "?")\(outside)")
            lines.append("Verdict: \(status.identity.matches(bundled) ? "match" : "MISMATCH")")
        } else {
            lines.append("Running: no status file")
        }
        lines.append("Auto-restart sentinel: \(Preferences.agentRestartedForIdentity ?? "none")")
        lines.append("Wallpaper mode: \(Preferences.wallpaperMode) (chosen=\(Preferences.wallpaperModeChosen)), desktop wallpaper active: \(WallpaperControl.shared.desktopWallpaperActive)")
        lines.append(contentsOf: WallpaperStoreSummary.describeCurrentStore())
        lines.append("")

        lines.append("== Plugin registrations (pluginkit -m -v) ==")
        let pluginkit = Helpers.shell(launchPath: "/usr/bin/pluginkit", arguments: ["-m", "-v"]) ?? ""
        let interesting = pluginkit
            .split(separator: "\n")
            .filter {
                let lower = $0.lowercased()
                return lower.contains("aerial") || lower.contains("glouel") || lower.contains("wallpaper")
            }
        lines.append(contentsOf: interesting.map(String.init))

        return lines.joined(separator: "\n") + "\n"
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private static func defaultArchiveName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "Aerial-Diagnostics-\(Helpers.version)-\(formatter.string(from: Date())).zip"
    }
}

// MARK: - Wallpaper store summary

/// Decoded view of the wallpaper store's active choices for the
/// diagnostics bundle. `describe(plist:)` is pure so the parsing is
/// unit-tested; a `placement` key on the Idle slot is what makes the
/// screensaver acquire carry `placement=Crop`.
enum WallpaperStoreSummary {
    static let storeURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    static func describeCurrentStore() -> [String] {
        guard let data = try? Data(contentsOf: storeURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return ["Wallpaper store: unreadable (\(storeURL.path))"]
        }
        return describe(plist: plist)
    }

    /// One line per section/slot: section type, provider, option keys.
    static func describe(plist: [String: Any]) -> [String] {
        var lines: [String] = []
        for name in ["AllSpacesAndDisplays", "SystemDefault"] {
            guard let section = plist[name] as? [String: Any] else {
                lines.append("Store \(name): missing")
                continue
            }
            let type = section["Type"] as? String ?? "?"
            for slot in ["Desktop", "Idle", "Linked"] {
                guard let slotDict = section[slot] as? [String: Any],
                      let content = slotDict["Content"] as? [String: Any] else { continue }
                let provider = ((content["Choices"] as? [[String: Any]])?.first?["Provider"] as? String) ?? "?"
                lines.append("Store \(name).\(slot) [\(type)]: \(provider) options=\(optionKeys(content["EncodedOptionValues"]))")
            }
        }
        if let spaces = plist["Spaces"] as? [String: Any], !spaces.isEmpty {
            lines.append("Store Spaces: \(spaces.count) per-space section(s)")
        }
        if let displays = plist["Displays"] as? [String: Any], !displays.isEmpty {
            lines.append("Store Displays: \(displays.count) per-display section(s)")
        }
        return lines
    }

    /// Top-level keys of the `{"values": {…}}` option plist, or why not.
    static func optionKeys(_ encoded: Any?) -> String {
        guard let data = encoded as? Data else { return "none" }
        guard let decoded = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let values = decoded["values"] as? [String: Any] else { return "undecodable" }
        return values.isEmpty ? "empty" : "[" + values.keys.sorted().joined(separator: ", ") + "]"
    }
}
