//
//  LegacySaverPrefs.swift
//  Aerial
//
//  The Aerial 3.x screensaver's preferences, read once by the first-launch
//  wizard. 3.x stored them through a `@SimpleStorage` wrapper backed by
//  `UserDefaults(suiteName: <prefs dir> + "com.glouel.Aerial")`, i.e. a
//  plist in the legacy screensaver container (`Data/Library/Preferences/`)
//  on Catalina and later, or in `~/Library/Preferences/` before that. The
//  wrapper changed encodings over the years — native values (3.6), JSON-
//  encoded strings, JSON data blobs — and one file can mix them, so every
//  key is decoded leniently.
//
//  What matters here is the custom support location. With `overrideCache`
//  on, 3.x used `<supportPath>/Aerial` as its root (it appended "Aerial"
//  to the chosen folder in every case — v3.6.3 `Cache.supportPath`), with
//  the video cache at `<root>/Cache`. The folder picker wrote the path
//  string and a security-scoped bookmark for the sandboxed saver; the
//  "manually pick" checkbox wrote the flag. Companion is not sandboxed, so
//  the string is enough and the bookmark is only a fallback.
//
//  Companion only. Logging is prefixed 🚚 like the rest of the migration.
//

import Foundation

struct LegacySaverPrefs: Equatable {
    let overrideCache: Bool
    let supportPath: String?
    let supportBookmarkData: Data?

    static let containerPlistPath = NSHomeDirectory()
        + "/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Preferences/com.glouel.Aerial.plist"
    static let homePlistPath = NSHomeDirectory() + "/Library/Preferences/com.glouel.Aerial.plist"

    struct Loaded: Equatable {
        let prefs: LegacySaverPrefs
        let path: String
    }

    enum LoadResult: Equatable {
        case found(Loaded)
        /// The plist exists but this process may not read it: the legacy
        /// screensaver container needs Full Disk Access (see
        /// `PathMigration.legacyDataReadable`).
        case denied(path: String)
        case none
    }

    /// The first candidate that exists. The container plist comes first:
    /// every sandboxed host (System Settings, the saver engine) on Catalina
    /// and later wrote there; the home one is the pre-Catalina layout. When
    /// the direct read is refused, cfprefsd is asked for the domain — that
    /// is how 3.x itself read it — and a denial is reported as such rather
    /// than falling back to a stale file elsewhere.
    static func load(candidates: [String] = [containerPlistPath, homePlistPath]) -> LoadResult {
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let plist = readPlist(at: path) {
                return .found(Loaded(prefs: parse(plist), path: path))
            }
            if let plist = readViaDefaults(at: path) {
                debugLog("🚚 Migration: read 3.x saver prefs at \(path) through cfprefsd (direct read denied)")
                return .found(Loaded(prefs: parse(plist), path: path))
            }
            errorLog("🚚 Migration: cannot read 3.x saver prefs at \(path) — Full Disk Access needed for the legacy screensaver container")
            return .denied(path: path)
        }
        return .none
    }

    private static func readPlist(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// The 3.x keys through cfprefsd; the domain is the plist path without
    /// its extension, exactly the suite name 3.x's storage wrapper used.
    /// Nil when the domain yields none of the keys 3.x always wrote.
    private static func readViaDefaults(at path: String) -> [String: Any]? {
        let domain = (path as NSString).deletingPathExtension
        guard let defaults = UserDefaults(suiteName: domain) else { return nil }
        var plist: [String: Any] = [:]
        for key in ["overrideCache", "supportPath", "supportBookmarkData",
                    "intVideoFormat", "firstTimeSetup", "lastVideoCheck", "debugMode"] {
            if let value = defaults.object(forKey: key) { plist[key] = value }
        }
        return plist.isEmpty ? nil : plist
    }

    /// Pure: the three keys, whatever encoding each one uses.
    static func parse(_ plist: [String: Any]) -> LegacySaverPrefs {
        LegacySaverPrefs(overrideCache: bool(plist["overrideCache"]) ?? false,
                         supportPath: string(plist["supportPath"]),
                         supportBookmarkData: data(plist["supportBookmarkData"]))
    }

    // MARK: - Lenient value decoding

    /// A JSON fragment (`true`, `"…"`) held in a string or a data blob.
    private static func jsonFragment(_ raw: Any?) -> Any? {
        let payload: Data?
        switch raw {
        case let string as String: payload = string.data(using: .utf8)
        case let data as Data: payload = data
        default: payload = nil
        }
        guard let payload else { return nil }
        return try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])
    }

    static func bool(_ raw: Any?) -> Bool? {
        if let native = raw as? Bool { return native }
        return jsonFragment(raw) as? Bool
    }

    static func string(_ raw: Any?) -> String? {
        if let native = raw as? String {
            // A JSON-encoded string starts with a quote; a path never does.
            return native.hasPrefix("\"") ? jsonFragment(native) as? String : native
        }
        if let blob = raw as? Data { return jsonFragment(blob) as? String }
        return nil
    }

    static func data(_ raw: Any?) -> Data? {
        if let native = raw as? Data {
            // A JSON blob holds a base64 string (JSONEncoder's default for
            // Data); a raw bookmark starts with "book" and is not JSON.
            if let base64 = jsonFragment(native) as? String, let decoded = Data(base64Encoded: base64) {
                return decoded
            }
            return native
        }
        if let string = raw as? String {
            if let base64 = jsonFragment(string) as? String, let decoded = Data(base64Encoded: base64) {
                return decoded
            }
            return Data(base64Encoded: string)
        }
        return nil
    }

    // MARK: - The 3.x layout

    /// The 3.x root: the chosen folder plus "Aerial", which 3.x appended in
    /// every case. The path string wins (the picker wrote it); the bookmark
    /// is resolved without security scope — Companion is not sandboxed and
    /// only needs the path. Standardized, no trailing slash.
    var customRoot: String? {
        var chosen: String?
        if let path = supportPath, !path.isEmpty {
            chosen = path
        } else if let bookmark = supportBookmarkData, !bookmark.isEmpty {
            var stale = false
            chosen = (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                               relativeTo: nil, bookmarkDataIsStale: &stale))?.path
        }
        guard let chosen, !chosen.isEmpty else { return nil }
        return URL(fileURLWithPath: chosen, isDirectory: true).standardizedFileURL
            .appendingPathComponent("Aerial", isDirectory: true).path
    }

    var hasOverride: Bool { overrideCache && customRoot != nil }

    /// `<root>/Cache` — where 3.x kept the videos — when the override is on.
    var customCacheFolder: String? {
        guard overrideCache, let root = customRoot else { return nil }
        return root + "/Cache"
    }

    /// Whether the 3.x cache is worth importing into 4.x. A folder that
    /// exists is. A root under /Volumes that is absent is too: the drive is
    /// unplugged and the 4.x legacy handling waits for it (`isAvailable`
    /// stays false, Settings › Cache says "Drive not connected", the mount
    /// observer re-offers the conversion). Anywhere else a missing folder
    /// must NOT be imported: the offer requires the folder to exist so no
    /// page would ever appear, downloads would stay blocked and nothing
    /// re-checks — a dead end. 4.x then simply keeps its default cache.
    static func isImportable(root: String, rootExists: Bool, cacheIsDirectory: Bool) -> Bool {
        cacheIsDirectory || (root.hasPrefix("/Volumes/") && !rootExists)
    }

    /// The importable cache folder as of now on disk; nil (reason logged)
    /// otherwise.
    func importableCacheFolder(fm: FileManager = .default) -> String? {
        guard let root = customRoot, let cache = customCacheFolder else { return nil }
        if cache == Cache.defaultCachePath {
            debugLog("🚚 Migration: 3.x custom cache \(cache) is the default location — nothing to import")
            return nil
        }
        var isDirectory: ObjCBool = false
        let cacheIsDirectory = fm.fileExists(atPath: cache, isDirectory: &isDirectory) && isDirectory.boolValue
        let rootExists = fm.fileExists(atPath: root)
        guard Self.isImportable(root: root, rootExists: rootExists, cacheIsDirectory: cacheIsDirectory) else {
            debugLog("🚚 Migration: 3.x custom root \(root) has no Cache folder — override ignored")
            return nil
        }
        return cache
    }
}
