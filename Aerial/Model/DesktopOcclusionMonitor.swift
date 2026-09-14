//
//  DesktopOcclusionMonitor.swift
//  Aerial Companion
//
//  Polls CGWindowListCopyWindowInfo to detect when other windows
//  cover the desktop video on a given screen.
//

import AppKit

protocol DesktopOcclusionDelegate: AnyObject {
    func occlusionDidChange(isOccluded: Bool)
}

class DesktopOcclusionMonitor {
    weak var delegate: DesktopOcclusionDelegate?

    /// Stable identifier for the screen we're watching. We resolve the
    /// screen's current CG bounds via `CGDisplayBounds(displayID)` on
    /// every poll instead of snapshotting at construction — so any
    /// display-arrangement change in macOS System Settings → Displays
    /// (rearrange, resolution change, scale-factor change) heals
    /// itself within the next 1-second tick.
    ///
    /// If `displayID` becomes invalid (display unplugged before the
    /// disconnect handler in PlaybackManager has torn us down),
    /// `CGDisplayBounds` returns `.null`, which `coverage(for:)`
    /// safely treats as 0% — no crash, no spurious pause.
    let displayID: CGDirectDisplayID

    private var timer: DispatchSourceTimer?
    private var isOccluded = false
    private var isCoolingDown = false

    init(displayID: CGDirectDisplayID, initialOccluded: Bool = false) {
        self.displayID = displayID
        self.isOccluded = initialOccluded
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + 1.0, repeating: 1.0)
        source.setEventHandler { [weak self] in
            self?.poll()
        }
        source.resume()
        timer = source
        debugLog("🖥️ OcclusionMonitor started for display=\(displayID) bounds=\(CGDisplayBounds(displayID))")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isCoolingDown = false
        debugLog("🖥️ OcclusionMonitor stopped")
    }

    func cooldown(seconds: TimeInterval) {
        isCoolingDown = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.isCoolingDown = false
        }
    }

    // MARK: - Polling

    private func poll() {
        guard !isCoolingDown else { return }

        let threshold = Preferences.desktopAutoPauseThreshold
        let coverage = computeCoverage()
        let nowOccluded = coverage >= threshold

        if nowOccluded != isOccluded {
            isOccluded = nowOccluded
            debugLog("🖥️ Occlusion changed: \(nowOccluded ? "occluded" : "visible") (coverage: \(Int(coverage * 100))%)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.occlusionDidChange(isOccluded: nowOccluded)
            }
        }
    }

    // MARK: - Coverage Calculation

    /// Compute current window coverage for a screen.
    ///
    /// `screenFrame` MUST be in CG global coordinates (top-left origin,
    /// Y down) — pass `NSScreen.cgBounds`, not `NSScreen.frame`. Window
    /// bounds from `CGWindowListCopyWindowInfo` are CG-space; passing
    /// an AppKit `frame` makes the intersection silently return empty
    /// for any non-main screen.
    ///
    /// Only counts normal app windows (level 0 up to but excluding the Dock level).
    /// Excludes: desktop background, Dock, menu bar, status bar, Aerial's own windows.
    /// Can be called from any thread.
    static func coverage(for screenFrame: CGRect) -> Double {
        let gridCols = 50
        let gridRows = 50
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Only count windows at normal level (0) up to but not including dock (20).
        // This includes normal windows, floating panels, modal panels, utility windows.
        // Excludes: desktop, dock, menu bar, status bar, notification center, etc.
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return 0
        }

        let totalCells = gridCols * gridRows
        var grid = [Bool](repeating: false, count: totalCells)
        let cellWidth = screenFrame.width / CGFloat(gridCols)
        let cellHeight = screenFrame.height / CGFloat(gridRows)

        for entry in windowList {
            // Skip our own windows (including our desktop-level video windows)
            if let pid = entry[kCGWindowOwnerPID] as? Int32, pid == ownPID { continue }

            // Only count regular app windows: level >= 0 (normal) and < dock level (20)
            // This filters out: desktop background (negative), Dock (20), menu bar (24),
            // status bar items (25), notification center, control center, etc.
            guard let layer = entry[kCGWindowLayer] as? Int,
                  layer >= 0, layer < dockLevel else { continue }

            guard let boundsRaw = entry[kCGWindowBounds] else { continue }
            let boundsDict = boundsRaw as! CFDictionary
            var windowRect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &windowRect) else { continue }
            let clipped = windowRect.intersection(screenFrame)
            guard !clipped.isNull && clipped.width > 0 && clipped.height > 0 else { continue }
            let minCol = max(0, Int((clipped.minX - screenFrame.minX) / cellWidth))
            let maxCol = min(gridCols - 1, Int((clipped.maxX - screenFrame.minX) / cellWidth))
            let minRow = max(0, Int((clipped.minY - screenFrame.minY) / cellHeight))
            let maxRow = min(gridRows - 1, Int((clipped.maxY - screenFrame.minY) / cellHeight))
            for row in minRow...maxRow {
                for col in minCol...maxCol {
                    grid[row * gridCols + col] = true
                }
            }
        }

        let coveredCells = grid.filter { $0 }.count
        return Double(coveredCells) / Double(totalCells)
    }

    private func computeCoverage() -> Double {
        // Fetch the screen's current CG bounds on every poll. macOS
        // System Settings → Displays rearranges (drag a tile, change
        // resolution) update what CGDisplayBounds returns; snapshotting
        // at init would leave us polling against the stale rect.
        return Self.coverage(for: CGDisplayBounds(displayID))
    }
}
