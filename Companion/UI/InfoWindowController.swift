//
//  InfoWindowController.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 03/08/2020.
//

import Cocoa
import SwiftUI

@available(macOS 11.0, *)
class InfoWindowController: NSWindowController {

    convenience init() {
        // Create the SwiftUI view
        let infoView = InfoView()
        let hostingController = NSHostingController(rootView: infoView)

        // Get the ideal size for the content
        let contentSize = hostingController.view.fittingSize

        // Create the window programmatically
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "About Aerial Companion"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
    }

    func showAboutWindow() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
