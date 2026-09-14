//
//  WallpaperStatusState.swift
//  Shared between Aerial4WallpaperExtension and the Companion app.
//
//  The reverse half of the wallpaper control channel. The forward half
//  (wallpaper-control.json) is fire-and-forget — Companion writes
//  commands with no acknowledgment and no way to know whether the
//  extension is even running. The extension serializes this small
//  status snapshot to `/Users/Shared/Aerial/wallpaper-status.json`
//  (every 30 s, plus on acquire / invalidate / control reconcile) and
//  posts a Darwin notification; Companion's WallpaperStatusMonitor
//  reads it and treats a fresh `lastSeen` as "the extension is alive".
//

import Foundation

struct WallpaperStatusState: Codable, Equatable {
    /// Extension process id — changes on every respawn.
    var pid: Int = 0

    /// Wall-clock of the last write. Companion treats the extension as
    /// running while this is at most ~90 s old (writes land every 30 s).
    var lastSeen: Date = .distantPast

    /// True while any renderer is driving screensaver subscribers.
    var saverActive: Bool = false

    /// True while any wallpaper sits in the system's `locked`
    /// presentation mode (login screen up).
    var lockedActive: Bool = false

    /// Renderer keys ("broadcast" or screen UUIDs) whose renderer is
    /// currently paused (any reason).
    var pausedScreens: [String] = []

    /// Screen UUIDs paused by the auto-pause (window coverage) signal,
    /// per the extension's last-applied control state.
    var autoPausedScreens: [String] = []

    /// Renderer key → current video display name.
    var nowPlaying: [String: String] = [:]

    /// Renderer key → current video *id*. Unlike `nowPlaying` (a display
    /// name) this maps back to a `PlaylistEntry`, so Companion can sync
    /// each display's playlist position to what the extension actually
    /// renders (the dashboard/popover "now playing" + highlight).
    var nowPlayingId: [String: String] = [:]

    /// Renderer key → playback position within the current video in
    /// content-seconds at `lastSeen`. Companion interpolates
    /// `position + (now − lastSeen) × rate` for a live progress bar —
    /// no per-second IPC needed.
    var nowPlayingPosition: [String: Double] = [:]

    /// Renderer key → current TIMEBASE rate (0 when paused, 1.0 during
    /// saver/lock, else the nominal wallpaper rate) — the interpolation
    /// slope for `nowPlayingPosition`.
    var nowPlayingRate: [String: Double] = [:]

    /// Version of the control state the extension last applied. Companion
    /// compares this against its own counter to detect a deaf extension
    /// (missed Darwin notification) and re-post.
    var appliedControlVersion: Int = 0

    /// Identity of the RUNNING extension, captured at its launch (see
    /// `WallpaperExtensionIdentity`). Empty / 0 from extensions that
    /// predate these fields — Companion treats that as "unknown", i.e.
    /// certainly older than itself.
    var extensionVersion: String = ""
    var extensionBuild: String = ""
    var extensionBinaryModified: Double = 0

    var identity: WallpaperExtensionIdentity {
        get {
            WallpaperExtensionIdentity(version: extensionVersion,
                                       build: extensionBuild,
                                       binaryModified: extensionBinaryModified)
        }
        set {
            extensionVersion = newValue.version
            extensionBuild = newValue.build
            extensionBinaryModified = newValue.binaryModified
        }
    }

    static let fileURL = URL(fileURLWithPath: "/Users/Shared/Aerial/wallpaper-status.json")

    /// Posted by the extension after every status write.
    static let darwinNotificationName = "com.glouel.aerial.wallpaper-status"
}

// Tolerant decoding: fields added over time default instead of failing
// the whole read (same rationale as WallpaperControlState).
extension WallpaperStatusState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? .distantPast
        saverActive = try c.decodeIfPresent(Bool.self, forKey: .saverActive) ?? false
        lockedActive = try c.decodeIfPresent(Bool.self, forKey: .lockedActive) ?? false
        pausedScreens = try c.decodeIfPresent([String].self, forKey: .pausedScreens) ?? []
        autoPausedScreens = try c.decodeIfPresent([String].self, forKey: .autoPausedScreens) ?? []
        nowPlaying = try c.decodeIfPresent([String: String].self, forKey: .nowPlaying) ?? [:]
        nowPlayingId = try c.decodeIfPresent([String: String].self, forKey: .nowPlayingId) ?? [:]
        nowPlayingPosition = try c.decodeIfPresent([String: Double].self, forKey: .nowPlayingPosition) ?? [:]
        nowPlayingRate = try c.decodeIfPresent([String: Double].self, forKey: .nowPlayingRate) ?? [:]
        appliedControlVersion = try c.decodeIfPresent(Int.self, forKey: .appliedControlVersion) ?? 0
        extensionVersion = try c.decodeIfPresent(String.self, forKey: .extensionVersion) ?? ""
        extensionBuild = try c.decodeIfPresent(String.self, forKey: .extensionBuild) ?? ""
        extensionBinaryModified = try c.decodeIfPresent(Double.self, forKey: .extensionBinaryModified) ?? 0
    }
}

// MARK: - Extension identity

/// Which build of the wallpaper extension a process IS: marketing
/// version, build number and the executable's modification time. The
/// extension captures its own identity at launch
/// (`runningExtensionIdentity`) and echoes it in every status write;
/// Companion compares that with the appex bundled inside itself to
/// detect a WallpaperAgent still hosting a pre-update binary. The mtime
/// is what separates two dev builds at the same version/build.
struct WallpaperExtensionIdentity: Equatable, CustomStringConvertible {
    var version: String = ""
    var build: String = ""
    /// Executable mtime, seconds since 1970; 0 when unknown.
    var binaryModified: Double = 0

    /// Archive round-trips (zip → Sparkle) keep mtimes to ~1 s; two
    /// stamps this close are the same file.
    static let binaryModifiedTolerance: TimeInterval = 2

    /// False for status written by an extension older than these fields
    /// (or when the bundle couldn't be read).
    var isKnown: Bool { !build.isEmpty }

    static func of(bundle: Bundle) -> WallpaperExtensionIdentity {
        var identity = WallpaperExtensionIdentity()
        let info = bundle.infoDictionary ?? [:]
        identity.version = info["CFBundleShortVersionString"] as? String ?? ""
        identity.build = info["CFBundleVersion"] as? String ?? ""
        if let path = bundle.executablePath,
           let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let date = attrs[.modificationDate] as? Date {
            identity.binaryModified = date.timeIntervalSince1970
        }
        return identity
    }

    func matches(_ other: WallpaperExtensionIdentity) -> Bool {
        guard isKnown, other.isKnown else { return false }
        return version == other.version
            && build == other.build
            && abs(binaryModified - other.binaryModified) <= Self.binaryModifiedTolerance
    }

    var description: String {
        guard isKnown else { return "unknown" }
        let stamp = Self.stampFormatter.string(from: Date(timeIntervalSince1970: binaryModified))
        return "\(version) (\(build), bin \(stamp))"
    }

    private static let stampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
