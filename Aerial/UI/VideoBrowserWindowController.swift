//
//  VideoBrowserWindowController.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 26/05/2026.
//

import Cocoa
import SwiftUI

// macOS 15.1 fallback: SwiftUI `Window` scene with .defaultLaunchBehavior(.suppressed) fails to materialise reliably on early 15.x when the app is LSUIElement/.accessory. Use NSWindow + NSHostingController on <15.2.
@MainActor
final class VideoBrowserWindowController: NSWindowController {
    static let shared = VideoBrowserWindowController()

    private convenience init() {
        let hosting = NSHostingController(rootView: VideoBrowserView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Video Library"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 550)
        window.center()
        self.init(window: window)
    }

    static func show(via openWindow: OpenWindowAction) {
        // 15.6 not 15.2: highest 15.x we tested. 15.x doesn't render Tahoe chrome anyway, so NSWindow is visually identical.
        if #available(macOS 15.6, *) {
            openWindow(id: "videoBrowser")
        } else {
            shared.showWindow(nil)
            shared.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static func show(category: BrowseCategory, via openWindow: OpenWindowAction) {
        VideoBrowserState.pendingInitialCategory = category
        show(via: openWindow)
        // Defer post until next runloop tick so a brand-new window's onReceive observer has time to mount.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: VideoBrowserState.openCategoryRequest,
                object: category
            )
        }
    }
}
