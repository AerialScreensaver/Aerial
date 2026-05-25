//
//  NSScreen+Id.swift
//  Aerial Companion
//
//  Created by Jared Furlow on 6/25/21.
//

import AppKit

// From https://gist.github.com/salexkidd/bcbea2372e92c6e5b04cbd7f48d9b204
extension NSScreen {

    public var screenUuid: String {
        return CFUUIDCreateString(nil, CGDisplayCreateUUIDFromDisplayID(deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID).takeRetainedValue()) as String
    }

    static public func getScreenByUuid(_ screenUuid: String) -> NSScreen? {
        for screen in NSScreen.screens {
            if screen.screenUuid == screenUuid {
                return screen
            }
        }

        return nil
    }

    /// Screen bounds in CG global coordinates (top-left origin, Y down).
    /// Use this when the value will be compared against window bounds
    /// from `CGWindowListCopyWindowInfo` / `kCGWindowBounds` — those are
    /// CG-space too. `NSScreen.frame` is AppKit-space (bottom-left
    /// origin, Y up); the two systems agree on the main display (both
    /// originate at (0,0)) but flip on Y for any screen positioned above
    /// or below the main in the desktop arrangement, so intersecting
    /// `frame` with CG window bounds silently returns the empty rect
    /// for those screens.
    ///
    /// Falls back to `frame` only when `NSScreenNumber` is missing —
    /// shouldn't happen for normal hardware; the fallback preserves
    /// previous behaviour rather than crashing.
    var cgBounds: CGRect {
        let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        return displayID.map { CGDisplayBounds($0) } ?? frame
    }
}
