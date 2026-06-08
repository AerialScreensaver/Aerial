//
//  ScreensaverManager.swift
//  Aerial Companion
//

import Foundation
import PaperSaverKit

enum AppLocation {
    case systemApplications   // /Applications/
    case userApplications     // ~/Applications/
    case other(String)        // somewhere else
}

/// One pluginkit registration of our screensaver extension bundle id.
/// We only ever track/act on the ones whose path is NOT the running app's
/// embedded `.appex` (i.e. stale duplicates from old archives / build copies).
struct PluginRegistration: Identifiable {
    let version: String
    let path: String
    var id: String { path }
}

/// Central plugin manager for the appex screensaver extension
class AerialPluginManager: ObservableObject {
    static let shared = AerialPluginManager()

    // MARK: - Constants

    let bundleIdentifier = "com.glouel.Aerial-App.AerialScreenSaverExtension"
    let screensaverDisplayName = "AerialScreenSaverExtension"

    // MARK: - Published State

    @Published var appLocation: AppLocation = .other("")
    @Published var isPluginRegistered: Bool = false
    @Published var isScreensaverEnabled: Bool = false
    /// Stale duplicate registrations of our extension bundle id (paths other
    /// than the running app's embedded `.appex`). Duplicates make the system's
    /// ExtensionKit context setup fail silently, so the screensaver inits but
    /// never starts. Surfaced (debug mode for now) so the user can clean them.
    @Published var staleRegistrations: [PluginRegistration] = []

    // MARK: - Private

    private let paperSaver = PaperSaver()

    private init() {
        refreshAll()
    }

    // MARK: - Checks

    func checkAppLocation() {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasPrefix("/Applications/") {
            appLocation = .systemApplications
        } else {
            let userAppsPath = NSHomeDirectory() + "/Applications/"
            if bundlePath.hasPrefix(userAppsPath) {
                appLocation = .userApplications
            } else {
                appLocation = .other(bundlePath)
            }
        }
    }

    func checkPluginRegistered() {
        do {
            let output = try runProcess("/usr/bin/pluginkit", arguments: ["-m", "-v", "-p", "com.apple.screensaver"])
            let lines = output.components(separatedBy: "\n")
            isPluginRegistered = lines.contains { $0.contains(bundleIdentifier) }
        } catch {
            errorLog("Failed to query pluginkit: \(error.localizedDescription)")
            isPluginRegistered = false
        }
    }

    func checkScreensaverEnabled() {
        // Use the per-Space API rather than `getActiveScreensavers()`.
        // The latter returns the UNION of screensavers across every
        // Space on every monitor, so changing the current Space's
        // screensaver to something else still leaves Aerial in the
        // set as long as it's active on any other Space — the popover
        // banner then misses the change. `getActiveScreensaver(for: nil)`
        // walks the space tree and returns the screensaver attached to
        // the `is_current` Space, which is what the user means by
        // "my active screensaver right now".
        if let info = paperSaver.getActiveScreensaver(for: nil) {
            isScreensaverEnabled = info.identifier == screensaverDisplayName
                || info.name == screensaverDisplayName
        } else {
            isScreensaverEnabled = false
        }
    }

    // MARK: - Actions

    func registerPlugin() {
        guard let extensionURL = Bundle.main.builtInPlugInsURL?.appendingPathComponent("AerialScreenSaverExtension.appex") else {
            errorLog("Cannot find built-in plugins URL")
            return
        }

        let extensionPath = extensionURL.path
        guard FileManager.default.fileExists(atPath: extensionPath) else {
            errorLog("Extension not found at: \(extensionPath)")
            return
        }

        debugLog("Registering plugin from: \(extensionPath)")
        do {
            _ = try runProcess("/usr/bin/pluginkit", arguments: ["-a", extensionPath])
            debugLog("Plugin registered successfully")
            checkPluginRegistered()
        } catch {
            errorLog("Failed to register plugin: \(error.localizedDescription)")
        }
    }

    func enableScreensaver() async {
        debugLog("Enabling \(screensaverDisplayName) screensaver via PaperSaver...")
        do {
            try await paperSaver.setScreensaverEverywhere(module: screensaverDisplayName)
            debugLog("Screensaver enabled successfully")
            checkScreensaverEnabled()
        } catch {
            errorLog("Failed to enable screensaver: \(error.localizedDescription)")
        }
    }

    /// Scan ALL registrations of our extension bundle id and flag any whose
    /// path isn't the running app's embedded `.appex`. `-A` is required: a
    /// plain `-m -p com.apple.screensaver` only returns the single elected
    /// plugin, hiding the duplicates that actually break context setup.
    func scanScreensaverRegistrations() {
        guard let canonical = canonicalExtensionPath() else {
            staleRegistrations = []
            return
        }
        do {
            let output = try runProcess("/usr/bin/pluginkit", arguments: ["-m", "-A", "-v", "-i", bundleIdentifier])
            var stale: [PluginRegistration] = []
            for rawLine in output.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.contains(bundleIdentifier) else { continue }
                // Verbose format: "<bundleid>(<version>)\t<uuid>\t<date>\t<path>"
                let fields = line.components(separatedBy: "\t")
                guard let last = fields.last?.trimmingCharacters(in: .whitespaces),
                      last.hasPrefix("/") else { continue }
                guard normalizedPath(last) != canonical else { continue }
                stale.append(PluginRegistration(version: extractVersion(from: fields[0]), path: last))
            }
            staleRegistrations = stale
        } catch {
            errorLog("Failed to scan pluginkit registrations: \(error.localizedDescription)")
            staleRegistrations = []
        }
    }

    /// Unregister every stale duplicate via `pluginkit -r <path>`. Only ever
    /// touches our own bundle id at non-canonical paths (never the running
    /// app's embedded `.appex`, never other bundles). Re-scans afterward.
    func removeStaleRegistrations() {
        let toRemove = staleRegistrations
        guard !toRemove.isEmpty else { return }
        for reg in toRemove {
            do {
                debugLog("Removing stale screensaver registration (\(reg.version)): \(reg.path)")
                _ = try runProcess("/usr/bin/pluginkit", arguments: ["-r", reg.path])
            } catch {
                errorLog("Failed to remove stale registration \(reg.path): \(error.localizedDescription)")
            }
        }
        refreshAll()
    }

    func refreshAll() {
        checkAppLocation()
        checkPluginRegistered()
        checkScreensaverEnabled()
        scanScreensaverRegistrations()
    }

    // MARK: - Private Helpers

    /// The running app's embedded extension path — the one "correct"
    /// registration. Any registration of our bundle id elsewhere is stale.
    private func canonicalExtensionPath() -> String? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("AerialScreenSaverExtension.appex") else {
            return nil
        }
        return normalizedPath(url.path)
    }

    private func normalizedPath(_ path: String) -> String {
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Pull the version out of a pluginkit field like
    /// `com.glouel.Aerial-App.AerialScreenSaverExtension(4.0.10)`.
    private func extractVersion(from field: String) -> String {
        guard let open = field.firstIndex(of: "("),
              let close = field.lastIndex(of: ")"),
              open < close else { return "?" }
        return String(field[field.index(after: open)..<close])
    }

    private func runProcess(_ path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
