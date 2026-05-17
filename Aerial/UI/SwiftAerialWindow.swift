//
//  SwiftAerialWindow.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 15/08/2025.
//  Swift replacement for ObjC AerialWindow, using direct compilation instead of dlopen
//

import Cocoa

class SwiftAerialWindow: NSWindowController {
    private weak var mainView: NSView!

    private var aerialView: AerialSaverView?

    init() {
        // Build the fullscreen-capable window here so `self.window` is
        // non-nil from the moment the controller exists. Frame is
        // cosmetic — `toggleFullScreen(nil)` immediately replaces it
        // with the screen's frame — but we keep 1280×720 to match the
        // old XIB's pre-fullscreen size in case any log mentions it.
        //
        // Programmatic construction via super.init(window:). NSWindow-
        // Controller's lazy-load path only fires for non-nil
        // `windowNibName`, so the override-loadWindow approach can't
        // work for a no-nib controller — construct eagerly instead.
        let frame = NSRect(x: 196, y: 240, width: 1280, height: 720)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Aerial"
        window.hasShadow = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.collectionBehavior = [.fullScreenPrimary]
        window.allowsToolTipsWhenApplicationIsInactive = false
        window.autorecalculatesKeyViewLoop = false
        window.animationBehavior = .none

        // contentView serves as the `mainView` anchor for the
        // auto-laid-out AerialSaverView added in setupWindowMode().
        let contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        contentView.autoresizesSubviews = true
        window.contentView = contentView

        super.init(window: window)
        self.mainView = contentView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported — SwiftAerialWindow is constructed programmatically")
    }

    /// Replaces the old `windowDidLoad()`. Re-runnable on every
    /// `windowMode()` call — the controller and window persist across
    /// close/reopen cycles but the AerialSaverView is torn down by
    /// `stopScreensaver()` and must be rebuilt. Tears down any
    /// previous view first.
    func setupWindowMode() {
        // Tear down any previous AerialSaverView. `aerialView` is
        // already nil after stopScreensaver, but be defensive in case
        // setup is called twice without an intervening stop.
        aerialView?.stopAnimation()
        aerialView?.removeFromSuperview()
        aerialView = nil

        guard let window = window else {
            errorLog("SwiftAerialWindow: No window available")
            return
        }

        // Create AerialSaverView with the screen UUID
        let frame = CGRect(x: 0, y: 0,
                          width: window.frame.size.width,
                          height: window.frame.size.height)

        let screenUUID = window.screen?.screenUuid ?? ""
        aerialView = AerialSaverView(frame: frame, screenUUID: screenUUID)

        guard let aerialView = aerialView else {
            errorLog("SwiftAerialWindow: Failed to create AerialSaverView")
            return
        }

        // Add the aerial view to the main view
        mainView.addSubview(aerialView)

        // Configure constraints to fill the parent view
        aerialView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            aerialView.topAnchor.constraint(equalTo: mainView.topAnchor),
            aerialView.bottomAnchor.constraint(equalTo: mainView.bottomAnchor),
            aerialView.leadingAnchor.constraint(equalTo: mainView.leadingAnchor),
            aerialView.trailingAnchor.constraint(equalTo: mainView.trailingAnchor)
        ])

        // viewDidMoveToWindow() will trigger playback automatically
    }

    // MARK: - Control Methods

    func setUserPaused(_ paused: Bool) {
        aerialView?.setUserPaused(paused)
    }

    func batteryPause() {
        aerialView?.batteryPause()
    }

    func batteryResume() {
        aerialView?.batteryResume()
    }

    func skipTo(playlistIndex: Int) {
        aerialView?.skipTo(playlistIndex: playlistIndex)
    }

    func skipToNext() {
        aerialView?.skipToNext()
    }

    func skipToPrevious() {
        aerialView?.skipToPrevious()
    }

    func changeSpeed(_ speed: Float) {
        aerialView?.setGlobalSpeed(speed)
    }

    func stopScreensaver() {
        aerialView?.stopAnimation()
        aerialView?.removeFromSuperview()
        aerialView = nil
    }
}
