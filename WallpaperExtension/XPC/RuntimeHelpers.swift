// Runtime helpers for constructing WallpaperExtensionKit XPC objects.
//
// These use class_createInstance + ivar writes because the real types
// don't expose Swift-accessible initializers.

import Foundation
import IOSurface

/// Construct a WallpaperRemoteContextXPC wrapping the given CAContext ID.
/// The real class has a `box` ivar (or offset 8 fallback) containing a
/// WallpaperExtensionRemoteContext with a single UInt32 remoteContextID.
func createRemoteContextXPC(contextId: UInt32) -> AnyObject? {
    guard let realClass = objc_getClass("WallpaperRemoteContextXPC") as? AnyClass,
          let raw = class_createInstance(realClass, 0) else {
        debugLog("  ERROR: Could not create WallpaperRemoteContextXPC")
        return nil
    }

    let obj = raw as AnyObject
    let ptr = Unmanaged.passUnretained(obj).toOpaque()
    let ivarOffset: Int = if let ivar = class_getInstanceVariable(realClass, "box") {
        ivar_getOffset(ivar)
    } else {
        8
    }
    ptr.advanced(by: ivarOffset).storeBytes(of: contextId, as: UInt32.self)
    debugLog("  Created WallpaperRemoteContextXPC (contextId: \(contextId), offset: \(ivarOffset))")
    return obj
}

/// Construct a WallpaperSnapshotXPC wrapping the given IOSurface.
/// The real class has a single `rawValue` ivar at offset 8 containing
/// a WallpaperSnapshot struct (8 bytes = IOSurface refcounted pointer).
func createSnapshotXPC(surface: IOSurface) -> AnyObject? {
    guard let snapshotXPCClass = objc_getClass("WallpaperSnapshotXPC") as? AnyClass,
          let instance = class_createInstance(snapshotXPCClass, 0) else {
        debugLog("  [Snapshot] Failed to create WallpaperSnapshotXPC")
        return nil
    }

    let surfaceRef = Unmanaged.passRetained(surface).toOpaque()
    let instancePtr = Unmanaged.passUnretained(instance as AnyObject).toOpaque()
    instancePtr.advanced(by: 8).storeBytes(of: surfaceRef, as: UnsafeRawPointer.self)
    return instance as AnyObject
}
