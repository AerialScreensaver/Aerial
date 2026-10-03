//
//  DarkMode.swift
//  Aerial
//
//  Created by Guillaume Louel on 19/12/2019.
//  Copyright © 2019 Guillaume Louel. All rights reserved.
//

import Foundation
import Cocoa

/// Process-wide mirror of the system appearance, read by the time-slice
/// rule ("only night videos in Dark Mode", the Light/Dark Mode time mode).
///
/// Nothing here observes the system: each process feeds it from the
/// source it actually has. The wallpaper extension gets the appearance
/// from WallpaperAgent on every acquire/update (`ctx.systemAppearance`),
/// Companion watches `NSApp.effectiveAppearance`
/// (`TimeAdaptationCoordinator`). Until the first `update`, the value is
/// `false` — the 3.x saver seeded it from the view's effective
/// appearance at init, a call that was lost in the appex migration and
/// left this permanently off.
struct DarkMode {
    /// Written from the XPC/KVO side, read from the renderer queues at
    /// every pop — keep the Bool behind a lock rather than racing it.
    private static let lock = NSLock()

    static func isEnabled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Aerial.helper.darkMode
    }

    /// Record the current appearance. Returns `true` when the value
    /// actually flipped, so callers can re-evaluate the slice rule only
    /// on a real change.
    @discardableResult
    static func update(isDark: Bool) -> Bool {
        lock.lock()
        let changed = Aerial.helper.darkMode != isDark
        if changed { Aerial.helper.darkMode = isDark }
        lock.unlock()
        if changed { debugLog("🌗 dark mode → \(isDark ? "on" : "off")") }
        return changed
    }
}
