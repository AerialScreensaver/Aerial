//
//  SwiftAerialDesktop.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 15/08/2025.
//  Swift replacement for ObjC AerialDesktop, using direct compilation instead of dlopen
//

import Cocoa

class SwiftAerialDesktop: NSWindowController {
    private var aerialView: CompanionAerialView?
    
    override var windowNibName: NSNib.Name? {
        return NSNib.Name("AerialDesktop")
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        
        guard let window = window, let screen = window.screen else {
            CompanionLogging.errorLog("SwiftAerialDesktop: No window or screen available")
            return
        }
        
        // Create a new CompanionAerialView of the window's inner size
        let frame = CGRect(x: 0, y: 0, 
                          width: screen.frame.size.width,
                          height: screen.frame.size.height)
        
        aerialView = CompanionAerialView(frame: frame)
        
        guard let aerialView = aerialView else {
            CompanionLogging.errorLog("SwiftAerialDesktop: Failed to create CompanionAerialView")
            return
        }
        
        // Set the aerial view as the window's content view
        window.contentView = aerialView
        
        // Configure window for desktop wallpaper mode
        window.setFrame(screen.frame, display: true, animate: false)
        
        // Set window level below desktop icons
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        
        // Configure window behavior for desktop wallpaper
        window.collectionBehavior = [
            .canJoinAllSpaces,
            //.stationary,
            .transient,
            .ignoresCycle
        ]
        window.canHide = false
        window.isOpaque = true
        window.isReleasedWhenClosed = false
        
        // Ensure window content resizes with window
        window.contentView?.autoresizesSubviews = true
        
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
        aerialView = nil
    }
    
    // MARK: - Panel Support
    
    func openPanel() {
        // This was for opening preferences panel - not currently used
        // Can be implemented later if needed using configureSheet
    }
}
