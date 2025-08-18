//
//  CompanionAerialView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 15/08/2025.
//  Direct wrapper around AerialView for type-safe usage in Companion app
//

#if COMPANION_APP
import AppKit
import AVFoundation

class CompanionAerialView: NSView {
    private let aerialView: AerialView
    
    override init(frame frameRect: NSRect) {
        // Create AerialView with isPreview=false for full functionality
        // This now uses direct compilation instead of dlopen
        aerialView = AerialView(frame: frameRect, isPreview: false)!
        super.init(frame: frameRect)
        setupAerialView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented - use init(frame:)")
    }
    
    private func setupAerialView() {
        addSubview(aerialView)
        aerialView.translatesAutoresizingMaskIntoConstraints = false
        
        // Pin AerialView to all edges of the container
        NSLayoutConstraint.activate([
            aerialView.topAnchor.constraint(equalTo: topAnchor),
            aerialView.bottomAnchor.constraint(equalTo: bottomAnchor),
            aerialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            aerialView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    
    // MARK: - AerialView Functionality Exposure
    
    /// Start the screensaver animation
    func startAnimation() {
        aerialView.startAnimation()
    }
    
    /// Stop the screensaver animation
    func stopAnimation() {
        aerialView.stopAnimation()
    }
    
    /// Get the current global playback speed
    func getGlobalSpeed() -> Float {
        return aerialView.getGlobalSpeed()
    }
    
    /// Set the global playback speed
    func setGlobalSpeed(_ speed: Float) {
        aerialView.setGlobalSpeed(speed)
    }
    
    /// Check if animation is currently running
    var isAnimating: Bool {
        return aerialView.isAnimating
    }
    
    /// Skip to next video
    func nextVideo() {
        aerialView.nextVideo()
    }
    
    /// Skip current video and hide it from future playback
    func skipAndHide() {
        aerialView.skipAndHide()
    }
    
    /// Toggle pause state
    func togglePause() {
        aerialView.togglePause()
    }
    
    // MARK: - Override NSView methods to delegate to AerialView
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Let AerialView handle its window lifecycle
    }
    
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Handle cleanup if needed
    }
    
    override var acceptsFirstResponder: Bool {
        return aerialView.acceptsFirstResponder
    }
    
    override func keyDown(with event: NSEvent) {
        // Forward key events to AerialView for screensaver controls
        aerialView.keyDown(with: event)
    }
    
    override func mouseDown(with event: NSEvent) {
        // Forward mouse events to AerialView
        aerialView.mouseDown(with: event)
    }
}

// MARK: - Factory Methods

extension CompanionAerialView {
    
    /// Create a CompanionAerialView for desktop wallpaper mode
    static func forDesktop(frame: NSRect) -> CompanionAerialView {
        return CompanionAerialView(frame: frame)
    }
    
    /// Create a CompanionAerialView for window mode
    static func forWindow(frame: NSRect) -> CompanionAerialView {
        return CompanionAerialView(frame: frame)
    }
    
    /// Create a CompanionAerialView for preview/testing
    static func forPreview(frame: NSRect) -> CompanionAerialView {
        // For previews, we might want different behavior
        return CompanionAerialView(frame: frame)
    }
}

#endif
