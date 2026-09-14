// Extension entry point.
//
// Loads WallpaperExtensionKit.framework via dlopen to register the
// runtime XPC type classes, swizzles WallpaperSnapshotXPC's encode
// to bypass the exact NSXPCCoder check, then surfaces the
// WallpaperExtensionConfig.

import AppKit
import ExtensionFoundation
import Foundation

@main
final class Aerial4WallpaperExtension: NSObject, AppExtension {
    override required init() {
        super.init()

        // Live display enumeration: NSScreen is frozen at first access
        // in this appex (no NSApplication run loop), so a monitor that
        // attaches after launch would never be found for spanned
        // slicing — see DisplayDetection.useCoreGraphicsEnumeration.
        // Must precede the first DisplayDetection.sharedInstance touch.
        DisplayDetection.useCoreGraphicsEnumeration = true

        // Logging first — everything below (and every static initializer
        // touched later) logs through the shared bridge into wallpaper.txt.
        LogBridge.configure(AerialLogger(config: LoggerConfiguration(
            logFileName: "wallpaper.txt",
            supportPath: { AerialPaths.logsPath() },
            category: "Extension",
            mirrorToOSLog: true,
            maxLogSize: 10_000_000
        )))

        // Last-resort crash trail: an NSException nobody caught (Apple
        // code on an XPC thread, a private selector gone after an OS
        // update) aborts this process — write name, reason and backtrace
        // to wallpaper.txt synchronously first. See ObjCException.swift.
        ObjCException.installUncaughtExceptionLogger()

        let frameworkPath = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        if let handle = dlopen(frameworkPath, RTLD_LAZY) {
            _ = handle  // keep open
            debugLog("INIT (PID: \(ProcessInfo.processInfo.processIdentifier), version=\(runningExtensionIdentity), build=\(buildTimestamp)) — WallpaperExtensionKit loaded")
            swizzleSnapshotEncodeIfNeeded()
            if PrefsAdvanced.debugMode {
                dumpWallpaperClassInventory(frameworkPath: frameworkPath)
            }
        } else {
            let err = String(cString: dlerror())
            debugLog("INIT (PID: \(ProcessInfo.processInfo.processIdentifier), version=\(runningExtensionIdentity), build=\(buildTimestamp)) — dlopen failed: \(err)")
        }

        // Prime the playlist subsystem. ExtensionVideoLoader.shared's
        // init calls VideoList.reloadSources() (reads cached manifests
        // from /Users/Shared/Aerial/ — no downloads). After this we can
        // ask getNextVideo(isVertical:screenUUID:) for the right pick
        // per display.
        _ = ExtensionVideoLoader.shared
        debugLog("  ExtensionVideoLoader primed (\(VideoList.instance.videos.count) videos)")

        // Prime the live-control channel listener. Registers the Darwin
        // notification observer and reads the current speed / counters
        // from `wallpaper-control.json` so a respawn picks up the last
        // Companion-set speed without waiting for the next notification.
        _ = WallpaperControlListener.shared

        // Announce this process (pid + build identity) right away: the
        // periodic status write is 30 s out and the first acquire may
        // never come (Aerial not the active wallpaper). Companion's
        // stale-build check and its "resolved" log key off this.
        writeWallpaperStatus(reason: "init")

        // Periodic playback-progress flush (30 s) so respawns resume
        // near the last position instead of restarting videos.
        startProgressFlusher()

        // Observe the login/password UI so overlays hide during login
        // even when the prompt appears over a running screensaver (the
        // agent's presentationMode doesn't signal that case). Gated on
        // the `hideOverlaysDuringLogin` setting inside the handler.
        registerLoginShieldObserver()

        // Second-layer screensaver detector: distributed-notification +
        // update()-idle fallback that sets/clears screensaver mode when the
        // agent's acquire-based detection (presentationMode=idle/placement=nil)
        // doesn't fire reliably (macOS 26/27). Additive — never overrides the
        // acquire path; the acquire/system path keeps priority on wake.
        registerScreensaverObserver()

        // Live dock-move detection for the overlay dock/menubar offset
        // (didChangeScreenParameters never fires in an appex).
        registerDockObserver()
    }

    /// Swizzle WallpaperSnapshotXPC.encodeWithCoder: to bypass the exact NSXPCCoder check.
    ///
    /// The system's encode does `type(of: coder) == NSXPCCoder.self`, but NSXPC hands
    /// the method an NSXPCEncoder (a subclass) — so the check fails and snapshots
    /// silently encode to nothing. We temporarily flip the coder's isa to NSXPCCoder
    /// for the call, then restore. Both classes implement `encodeXPCObject:forKey:`.
    private func swizzleSnapshotEncodeIfNeeded() {
        guard let snapshotClass = objc_getClass("WallpaperSnapshotXPC") as? AnyClass else {
            debugLog("  [Swizzle] WallpaperSnapshotXPC not found")
            return
        }

        let sel = NSSelectorFromString("encodeWithCoder:")
        guard let origMethod = class_getInstanceMethod(snapshotClass, sel) else {
            debugLog("  [Swizzle] encodeWithCoder: not found on WallpaperSnapshotXPC")
            return
        }

        let origIMP = method_getImplementation(origMethod)
        typealias EncodeFunc = @convention(c) (AnyObject, Selector, NSCoder) -> Void
        let origFunc = unsafeBitCast(origIMP, to: EncodeFunc.self)

        guard let nsxpcCoderClass = NSClassFromString("NSXPCCoder") else {
            debugLog("  [Swizzle] NSXPCCoder class not found")
            return
        }

        let block: @convention(block) (AnyObject, NSCoder) -> Void = { obj, coder in
            guard let origClass: AnyClass = object_getClass(coder) else {
                // No class to restore — run the original encoder untouched
                // rather than trap inside WallpaperAgent's XPC reply.
                origFunc(obj, sel, coder)
                return
            }
            object_setClass(coder, nsxpcCoderClass)
            // Catch here so a raise inside the system encoder can never
            // leave the coder's isa flipped; the snapshot then encodes to
            // nothing (the pre-swizzle behaviour) instead of aborting.
            ObjCException.attempt("WallpaperSnapshotXPC.encodeWithCoder:") {
                origFunc(obj, sel, coder)
            }
            object_setClass(coder, origClass)
        }
        let newIMP = imp_implementationWithBlock(block)
        method_setImplementation(origMethod, newIMP)
        debugLog("  [Swizzle] Patched WallpaperSnapshotXPC encodeWithCoder:")
    }

    /// One-shot dump of every Objective-C class shipped by
    /// WallpaperExtensionKit.framework that starts with "Wallpaper".
    /// This documents the private API surface — anything we don't see
    /// here doesn't exist; if a `WallpaperSpaceID` ever appears, the
    /// log will tell us so we don't have to guess.
    private func dumpWallpaperClassInventory(frameworkPath: String) {
        var count: UInt32 = 0
        guard let classNames = objc_copyClassNamesForImage(frameworkPath, &count) else {
            debugLog("  [Classes] objc_copyClassNamesForImage returned nil")
            return
        }
        defer { free(UnsafeMutableRawPointer(mutating: classNames)) }
        debugLog("  [Classes] WallpaperExtensionKit class inventory (count=\(count)):")
        for i in 0..<Int(count) {
            let name = String(cString: classNames[i])
            if name.hasPrefix("Wallpaper") || name.hasPrefix("_Wallpaper") {
                debugLog("    \(name)")
            }
        }
    }

    var configuration: some AppExtensionConfiguration {
        WallpaperExtensionConfig()
    }
}
