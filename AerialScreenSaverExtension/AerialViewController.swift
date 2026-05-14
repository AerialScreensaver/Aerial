//
//  AerialViewController.swift
//  AerialScreenSaverExtension
//
//  View controller for the Aerial screensaver extension.
//

import AppKit
import ScreenSaver

/// View controller that manages the screensaver view.
/// The system instantiates this class based on the Info.plist configuration.
@objc(AerialViewController)
class AerialViewController: ScreenSaverViewController {

    /// Strong reference to prevent view from being deallocated
    private var saverView: AerialSaverView?

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        debugLog("AerialViewController.init(nibName:bundle:)")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        debugLog("AerialViewController.init(coder:)")
    }

    deinit {
        debugLog("AerialViewController.deinit")
    }

    override func loadView() {
        debugLog("AerialViewController.loadView() called")

        // Get the frame from the main screen, or use a default
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        debugLog("  frame: \(frame.size.width) x \(frame.size.height)")

        // Determine if this is a preview by checking the frame size
        let isPreview = frame.width < 400
        debugLog("  isPreview: \(isPreview)")

        saverView = AerialSaverView(frame: frame, isPreview: isPreview)

        if let sv = saverView {
            self.view = sv
            debugLog("AerialViewController.loadView() completed - view set")
        } else {
            errorLog("Failed to create AerialSaverView, using fallback")
            self.view = NSView(frame: frame)
        }
    }
}
