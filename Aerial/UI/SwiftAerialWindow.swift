//
//  SwiftAerialWindow.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 15/08/2025.
//  Swift replacement for ObjC AerialWindow, using direct compilation instead of dlopen
//

import Cocoa

class SwiftAerialWindow: NSWindowController {
    @IBOutlet weak var mainView: NSView!

    private var aerialView: AerialSaverView?

    override var windowNibName: NSNib.Name? {
        return NSNib.Name("AerialWindow")
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        window?.contentView?.autoresizesSubviews = true
    }

    override func windowDidLoad() {
        super.windowDidLoad()

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
