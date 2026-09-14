// Diagnostics helpers for the wallpaper extension. Logging itself goes
// through the shared AerialLogger/LogBridge (configured to wallpaper.txt
// in Aerial4WallpaperExtension.init) — this file holds what's left:
// the deferrable-diagnostics queue, the build stamp, and the Mirror
// dumper for private WallpaperExtensionKit XPC types.

import Foundation

/// Serial queue for deferrable diagnostics (topology dumps, geometry
/// audits) that must stay off the XPC thread — building those strings
/// queue.syncs into renderer queues and used to serialize multi-display
/// acquires.
let extensionDiagnosticsQueue = DispatchQueue(label: "com.glouel.aerial.wallpaper-diagnostics", qos: .utility)

/// Timestamp of the extension binary's last modification. Used to confirm
/// the running extension matches a recent build — if this prints a stale
/// value in the log, WallpaperAgent is still hosting an old binary and
/// needs a kick (`killall WallpaperAgent`).
let buildTimestamp: String = {
    guard let path = Bundle.main.executablePath,
          let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let date = attrs[.modificationDate] as? Date
    else { return "unknown" }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: date)
}()

/// Version / build / binary identity of THIS extension process, captured
/// at launch. Must be a launch-time constant: after an in-place app
/// update `Bundle.main` still points at the same path, and a lazy read
/// would report the NEW bundle's version for the OLD running binary —
/// the exact confusion this exists to detect. Echoed in every status
/// write so Companion can tell WallpaperAgent is hosting a stale build.
let runningExtensionIdentity = WallpaperExtensionIdentity.of(bundle: .main)

/// Recursively dump an object's Mirror for debugging XPC types whose
/// layouts we don't have public headers for. `depth` controls how deep
/// we descend into child values.
func dumpMirror(_ obj: Any, label: String = "root", depth: Int = 3, indent: Int = 0) {
    let prefix = String(repeating: "  ", count: indent)
    let mirror = Mirror(reflecting: obj)
    debugLog("\(prefix)[\(label)] type=\(type(of: obj)) children=\(mirror.children.count)")
    guard depth > 0 else { return }
    for child in mirror.children {
        let childLabel = child.label ?? "?"
        let childValue = child.value
        let desc = String(describing: childValue).prefix(200)
        debugLog("\(prefix)  .\(childLabel) = \(desc)")
        let childMirror = Mirror(reflecting: childValue)
        if childMirror.children.count > 0,
           !(childValue is String),
           !(childValue is Data),
           !(childValue is URL) {
            dumpMirror(childValue, label: childLabel, depth: depth - 1, indent: indent + 2)
        }
    }
}
