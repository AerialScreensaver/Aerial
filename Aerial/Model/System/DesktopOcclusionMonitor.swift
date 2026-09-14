//
//  DesktopOcclusionMonitor.swift
//  Aerial Companion
//
//  Computes how much of a screen's desktop video is covered by other
//  windows, from CGWindowListCopyWindowInfo snapshots. The always-on
//  1 Hz poll lives in WallpaperAutoPauseCoordinator; this type holds
//  the computation in two weights:
//   - coverages(for:) — the poll path: ONE window snapshot shared by
//     all screens, totals only, no app names/icons. App identity is
//     resolved only when the ignore list needs bundle IDs, through a
//     persistent pid cache (LaunchServices once per process, not once
//     per second — resolving name/id/icon per poll was ~70% of a
//     constant 4-8% idle CPU, 2026-07-24 sample).
//   - coverageDetails(for:) — the settings-UI version, additionally
//     reporting per-app contributions with names and icons.
//

import AppKit
import os

/// One app's contribution to the coverage grid, for the settings UI's
/// "apps covering the wallpaper" list.
struct OccludingAppInfo: Identifiable {
    /// Bundle identifier, or the CGWindowList owner name for processes
    /// without one. This is the value stored in
    /// `Preferences.desktopAutoPauseIgnoredApps` when the user ignores
    /// the app.
    let id: String
    let name: String
    let icon: NSImage?
    /// Fraction of the screen covered by this app's windows alone.
    let coverage: Double
}

enum DesktopOcclusionMonitor {
    private static let gridCols = 50
    private static let gridRows = 50

    /// pid → bundle identifier (nil = resolved, has none), so the poll
    /// path hits LaunchServices once per process lifetime instead of
    /// once per second per window owner. Entries for vanished pids are
    /// evicted each snapshot. Lock-protected: the poll queue and the
    /// coordinator's main-thread seed both call `coverages(for:)`.
    private static let bundleIDCache = OSAllocatedUnfairLock(initialState: [pid_t: String?]())

    /// Last poll's inputs → totals. Window layouts are static most of
    /// the time, so when the filtered rect list, screen frames, and
    /// ignore list all match the previous call, the grid math is
    /// skipped entirely — a steady-state poll costs one window
    /// snapshot plus an array compare.
    private struct CoverageMemo {
        var rects: [CGRect] = []
        var frames: [String: CGRect] = [:]
        var ignored: Set<String> = []
        var totals: [String: Double] = [:]
        var valid = false
    }
    private static let coverageMemo = OSAllocatedUnfairLock(initialState: CoverageMemo())

    /// pid → full app identity for the settings-UI details path, so the
    /// panel preview stops re-resolving names/icons through
    /// LaunchServices on every tick. Evicted like `bundleIDCache`.
    /// `uncheckedState`: NSImage is not Sendable, but entries are only
    /// created once and then read.
    private static let identityCache = OSAllocatedUnfairLock(
        uncheckedState: [pid_t: (id: String, name: String, icon: NSImage?)]()
    )

    // MARK: - Poll path (lean)

    /// Coverage totals for several screens from ONE window-server
    /// snapshot. `frames` values MUST be CG global coordinates
    /// (top-left origin, Y down) — pass `CGDisplayBounds(displayID)`,
    /// not `NSScreen.frame`; window bounds from CGWindowList are
    /// CG-space and the intersection silently returns empty otherwise.
    ///
    /// Only counts normal app windows (level 0 up to but excluding the
    /// Dock level). Excludes: desktop background, Dock, menu bar,
    /// status bar, Aerial's own windows, and any app in
    /// `Preferences.desktopAutoPauseIgnoredApps`. An unplugged
    /// display's `.null` bounds safely reads as 0% coverage. Can be
    /// called from any thread.
    static func coverages(for frames: [String: CGRect]) -> [String: Double] {
        guard !frames.isEmpty else { return [:] }
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return frames.mapValues { _ in 0 }
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ignored = Set(Preferences.desktopAutoPauseIgnoredApps)
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))

        // Filter the snapshot once; every screen's grid shares the
        // surviving rects.
        var rects: [CGRect] = []
        var seenPIDs = Set<pid_t>()
        for entry in windowList {
            // Skip our own windows (including our desktop-level video windows)
            let pid = entry[kCGWindowOwnerPID] as? Int32
            if pid == ownPID { continue }

            // Only count regular app windows: level >= 0 (normal) and < dock level (20)
            // This filters out: desktop background (negative), Dock (20), menu bar (24),
            // status bar items (25), notification center, control center, etc.
            guard let layer = entry[kCGWindowLayer] as? Int,
                  layer >= 0, layer < dockLevel else { continue }
            if let pid { seenPIDs.insert(pid) }

            // Ignore-list check — identity resolution only when the
            // list is non-empty. Raw owner-name match keeps entries
            // stored before a process became bundle-resolvable working.
            if !ignored.isEmpty {
                if let ownerName = entry[kCGWindowOwnerName] as? String,
                   ignored.contains(ownerName) { continue }
                if let pid {
                    let bundleID = bundleIDCache.withLock { $0[pid] } ?? {
                        let resolved = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                        // updateValue, not subscript: a nil bundle ID must
                        // stay cached (subscript-nil deletes the entry and
                        // helper processes would hit LaunchServices every
                        // poll again).
                        bundleIDCache.withLock { _ = $0.updateValue(resolved, forKey: pid) }
                        return resolved
                    }()
                    if let bundleID, ignored.contains(bundleID) { continue }
                }
            }

            guard let boundsRaw = entry[kCGWindowBounds] else { continue }
            let boundsDict = boundsRaw as! CFDictionary
            var windowRect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &windowRect) else { continue }
            rects.append(windowRect)
        }
        bundleIDCache.withLock { cache in
            cache = cache.filter { seenPIDs.contains($0.key) }
        }

        let cached: [String: Double]? = coverageMemo.withLock { memo in
            guard memo.valid, memo.rects == rects, memo.frames == frames,
                  memo.ignored == ignored else { return nil }
            return memo.totals
        }
        if let cached { return cached }

        let totals = frames.mapValues { coverageTotal(of: rects, in: $0) }
        coverageMemo.withLock {
            $0 = CoverageMemo(rects: rects, frames: frames, ignored: ignored,
                              totals: totals, valid: true)
        }
        return totals
    }

    /// Fraction of `screenFrame` covered by `rects`, on the shared
    /// 50×50 grid.
    private static func coverageTotal(of rects: [CGRect], in screenFrame: CGRect) -> Double {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return 0 }
        let totalCells = gridCols * gridRows
        var grid = [Bool](repeating: false, count: totalCells)
        let cellWidth = screenFrame.width / CGFloat(gridCols)
        let cellHeight = screenFrame.height / CGFloat(gridRows)
        var covered = 0
        for rect in rects {
            let clipped = rect.intersection(screenFrame)
            guard !clipped.isNull && clipped.width > 0 && clipped.height > 0 else { continue }
            let minCol = max(0, Int((clipped.minX - screenFrame.minX) / cellWidth))
            let maxCol = min(gridCols - 1, Int((clipped.maxX - screenFrame.minX) / cellWidth))
            let minRow = max(0, Int((clipped.minY - screenFrame.minY) / cellHeight))
            let maxRow = min(gridRows - 1, Int((clipped.maxY - screenFrame.minY) / cellHeight))
            for row in minRow...maxRow {
                for col in minCol...maxCol {
                    let index = row * gridCols + col
                    if !grid[index] {
                        grid[index] = true
                        covered += 1
                    }
                }
            }
        }
        return Double(covered) / Double(totalCells)
    }

    // MARK: - Settings-UI path (full breakdown)

    /// Single-screen convenience over the multi-frame version below.
    static func coverageDetails(for screenFrame: CGRect) -> (total: Double, apps: [OccludingAppInfo]) {
        coverageDetails(for: [screenFrame])[0]
    }

    /// Same computation as the poll path, additionally reporting which
    /// apps contribute to the coverage so the settings UI can list them
    /// and offer to ignore some. Apps in the ignore list count toward
    /// neither the total nor the breakdown. ONE window snapshot and one
    /// identity pass shared across all `frames` (index-aligned result,
    /// always `frames.count` entries). Resolves app names and icons —
    /// do NOT call from a steady-state poll; the DesktopSettingsPanel's
    /// while-visible timer is the intended consumer.
    static func coverageDetails(for frames: [CGRect]) -> [(total: Double, apps: [OccludingAppInfo])] {
        guard !frames.isEmpty else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ignored = Set(Preferences.desktopAutoPauseIgnoredApps)
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return frames.map { _ in (0, []) }
        }

        let totalCells = gridCols * gridRows
        var grids = frames.map { _ in [Bool](repeating: false, count: totalCells) }
        var perApp = frames.map { _ in [String: (name: String, icon: NSImage?, cells: Set<Int>)]() }
        var seenPIDs = Set<pid_t>()

        for entry in windowList {
            // Skip our own windows (including our desktop-level video windows)
            let pid = entry[kCGWindowOwnerPID] as? Int32
            if pid == ownPID { continue }

            guard let layer = entry[kCGWindowLayer] as? Int,
                  layer >= 0, layer < dockLevel else { continue }
            if let pid { seenPIDs.insert(pid) }

            let ownerName = entry[kCGWindowOwnerName] as? String
            let identity = resolveIdentity(pid: pid, ownerName: ownerName)

            // The user asked not to count this app's windows. Also match
            // the raw owner name so an entry stored before a process
            // became bundle-resolvable keeps working.
            if ignored.contains(identity.id) { continue }
            if let ownerName = ownerName, ignored.contains(ownerName) { continue }

            guard let boundsRaw = entry[kCGWindowBounds] else { continue }
            let boundsDict = boundsRaw as! CFDictionary
            var windowRect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &windowRect) else { continue }

            for (fi, screenFrame) in frames.enumerated() {
                guard screenFrame.width > 0, screenFrame.height > 0 else { continue }
                let clipped = windowRect.intersection(screenFrame)
                guard !clipped.isNull && clipped.width > 0 && clipped.height > 0 else { continue }
                let cellWidth = screenFrame.width / CGFloat(gridCols)
                let cellHeight = screenFrame.height / CGFloat(gridRows)
                let minCol = max(0, Int((clipped.minX - screenFrame.minX) / cellWidth))
                let maxCol = min(gridCols - 1, Int((clipped.maxX - screenFrame.minX) / cellWidth))
                let minRow = max(0, Int((clipped.minY - screenFrame.minY) / cellHeight))
                let maxRow = min(gridRows - 1, Int((clipped.maxY - screenFrame.minY) / cellHeight))
                var slot = perApp[fi][identity.id] ?? (name: identity.name, icon: identity.icon, cells: Set<Int>())
                for row in minRow...maxRow {
                    for col in minCol...maxCol {
                        let index = row * gridCols + col
                        grids[fi][index] = true
                        slot.cells.insert(index)
                    }
                }
                perApp[fi][identity.id] = slot
            }
        }
        identityCache.withLockUnchecked { cache in
            cache = cache.filter { seenPIDs.contains($0.key) }
        }

        return frames.indices.map { fi in
            let coveredCells = grids[fi].filter { $0 }.count
            let total = Double(coveredCells) / Double(totalCells)
            let apps = perApp[fi].map { id, info in
                OccludingAppInfo(id: id,
                                 name: info.name,
                                 icon: info.icon,
                                 coverage: Double(info.cells.count) / Double(totalCells))
            }.sorted { $0.coverage > $1.coverage }
            return (total, apps)
        }
    }

    /// pid → (bundle id, name, icon) through the persistent cache.
    /// NSRunningApplication resolves regular apps; helper processes
    /// without a LaunchServices registration fall back to the
    /// CGWindowList owner name (not cached — the fallback is free).
    private static func resolveIdentity(pid: pid_t?, ownerName: String?) -> (id: String, name: String, icon: NSImage?) {
        if let pid, let cached = identityCache.withLockUnchecked({ $0[pid] }) {
            return cached
        }
        let running = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        let name = running?.localizedName ?? ownerName ?? "Unknown"
        let identity = (id: running?.bundleIdentifier ?? ownerName ?? name,
                        name: name,
                        icon: running?.icon)
        if let pid {
            identityCache.withLockUnchecked { _ = $0.updateValue(identity, forKey: pid) }
        }
        return identity
    }
}
