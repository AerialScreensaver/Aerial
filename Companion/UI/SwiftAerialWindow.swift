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
    @IBOutlet weak var childView: NSView!
    
    private var aerialView: CompanionAerialView?
    
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
            CompanionLogging.errorLog("SwiftAerialWindow: No window available")
            return
        }
        
        // Create AerialView with window's size
        let frame = CGRect(x: 0, y: 0,
                          width: window.frame.size.width,
                          height: window.frame.size.height)
        
        aerialView = CompanionAerialView(frame: frame)
        
        guard let aerialView = aerialView else {
            CompanionLogging.errorLog("SwiftAerialWindow: Failed to create CompanionAerialView")
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
        
        // Start the animation
        aerialView.startAnimation()
    }
    
    // MARK: - Control Methods
    
    func togglePause() {
        aerialView?.togglePause()
    }
    
    func nextVideo() {
        aerialView?.nextVideo()
    }
    
    func skipAndHide() {
        aerialView?.skipAndHide()
    }
    
    func getSpeed() -> Float {
        return aerialView?.getGlobalSpeed() ?? 1.0
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