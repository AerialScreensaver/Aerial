//
//  DisplayView.swift
//  Aerial
//
//  Created by Guillaume Louel on 09/05/2019.
//  Copyright © 2019 John Coates. All rights reserved.
//

import Foundation
import Cocoa

class DisplayPreview: NSObject {
    var screen: Screen
    var previewRect: CGRect

    init(screen: Screen, previewRect: CGRect) {
        self.screen = screen
        self.previewRect = previewRect
    }
}

extension NSImage {
    func flipped(flipHorizontally: Bool = false, flipVertically: Bool = false) -> NSImage {
        let flippedImage = NSImage(size: size)

        flippedImage.lockFocus()

        NSGraphicsContext.current?.imageInterpolation = .high

        let transform = NSAffineTransform()
        transform.translateX(by: flipHorizontally ? size.width : 0, yBy: flipVertically ? size.height : 0)
        transform.scaleX(by: flipHorizontally ? -1 : 1, yBy: flipVertically ? -1 : 1)
        transform.concat()

        draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .sourceOver, fraction: 1)

        flippedImage.unlockFocus()

        return flippedImage
    }
}

class DisplayView: NSView {
    // We store our computed previews here
    var displayPreviews = [DisplayPreview]()

    // Callback for SwiftUI wrapper when a screen is toggled
    var onScreenToggled: (() -> Void)?

    // MARK: - Dashboard projection
    // Additive overlay used by the Video Library Dashboard's shared-mode
    // miniature. Default off → byte-identical Displays-settings behavior.
    // When on, the current video's thumbnail (`dashboardImage`) is drawn on
    // each active screen instead of the bundled `screenN.jpg` stock shots,
    // and is projected across the arrangement in spanned mode.
    var isDashboardMode: Bool = false
    var dashboardImage: NSImage?

    // MARK: - Mouse handling
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Lifecycle
    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
    }

    // MARK: - Drawing
    // swiftlint:disable:next cyclomatic_complexity
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // We need to handle dark mode
        let isDark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let backgroundColor = isDark ? NSColor(white: 0.2, alpha: 1.0) : NSColor(white: 0.9, alpha: 1.0)

        // let screenColor = NSColor.init(red: 0.38, green: 0.60, blue: 0.85, alpha: 1.0)
        let screenBorderColor = NSColor.black

        // Draw background
        backgroundColor.setFill()
        __NSRectFill(dirtyRect)

        let displayDetection = DisplayDetection.sharedInstance
        displayPreviews = [DisplayPreview]()    // Empty the array in case we redraw

        // In order to draw the screen we need to know the total size of all
        // the displays together
        let globalRect = displayDetection.getGlobalScreenRect()

        // Outer margin. The Displays-settings preview keeps its original
        // 30/60 px insets; the compact dashboard miniature uses a small
        // inset so the arrangement isn't dwarfed at card size.
        let m: CGFloat = isDashboardMode ? 8 : 30
        var minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat, scaleFactor: CGFloat
        if (frame.width / frame.height) > (globalRect.width / globalRect.height) {
            // We fill vertically then
            maxY = frame.height - (m * 2)
            minY = m
            scaleFactor = globalRect.height / maxY
            maxX = globalRect.width / scaleFactor
            minX = (frame.width - maxX)/2
        } else {
            // We fill horizontally
            maxX = frame.width - (m * 2)
            minX = m
            scaleFactor = globalRect.width / maxX
            maxY = globalRect.height / scaleFactor
            minY = (frame.height - maxY)/2
        }

        // In spanned mode, we start by a faint full view of the span
        if PrefsDisplays.viewingMode == .spanned {
            let activeRect = displayDetection.getZeroedActiveSpannedRect()
            debugLog("spanned active rect \(activeRect)")
            let activeSRect = NSRect(x: minX + (activeRect.origin.x/scaleFactor),
                               y: minY + (activeRect.origin.y/scaleFactor),
                               width: activeRect.width/scaleFactor,
                               height: activeRect.height/scaleFactor)

            if let image = spanImage() {
                image.draw(in: activeSRect, from: sourceRect(forTarget: activeSRect, image: image), operation: NSCompositingOperation.copy, fraction: 0.1)
            } else if !isDashboardMode {
                errorLog("\(#file) screenshot is missing!!!")
            }
        }

        var idx = 0
        var shouldFlip = true
        // Now we draw each individual screen
        for screen in displayDetection.screens {
            let sRect = NSRect(x: minX + (screen.zeroedOrigin.x/scaleFactor),
                               y: minY + (screen.zeroedOrigin.y/scaleFactor),
                               width: screen.bottomLeftFrame.width/scaleFactor,
                               height: screen.bottomLeftFrame.height/scaleFactor)

            let sPath = NSBezierPath(rect: sRect)
            screenBorderColor.setFill()
            sPath.fill()

            let sInRect = sRect.insetBy(dx: 1, dy: 1)

            if PrefsDisplays.viewingMode != .spanned {
                if displayDetection.isScreenActive(id: screen.id) {
                    var image = contentImage(stockIndex: idx)

                    if PrefsDisplays.viewingMode == .mirrored && shouldFlip {
                        image = image?.flipped(flipHorizontally: true, flipVertically: false)
                    }

                    shouldFlip.toggle()

                    if let image = image {
                        image.draw(in: sInRect, from: sourceRect(forTarget: sInRect, image: image), operation: NSCompositingOperation.copy, fraction: 1.0)
                    } else if !isDashboardMode {
                        errorLog("\(#file) screenshot is missing!!!")
                    }

                    // Show difference images in independant mode to simulate
                    if PrefsDisplays.viewingMode == .independent {
                        if idx < 2 {
                            idx += 1
                        } else {
                            idx = 0
                        }
                    }
                } else {
                    // If the screen is innactive we fill it with a near black color
                    let sInPath = NSBezierPath(rect: sInRect)
                    let grey = NSColor(white: 0.1, alpha: 1.0)
                    grey.setFill()
                    sInPath.fill()
                }
            } else {
                // Spanned mode
                if displayDetection.isScreenActive(id: screen.id) {
                    // Calculate which portion of the image to display
                    let activeRect = displayDetection.getZeroedActiveSpannedRect()
                    let activeSRect = NSRect(x: minX + (activeRect.origin.x/scaleFactor),
                                             y: minY + (activeRect.origin.y/scaleFactor),
                                             width: activeRect.width/scaleFactor,
                                             height: activeRect.height/scaleFactor)
                    let img = spanImage()
                    let ssRect = sourceRect(forTarget: activeSRect, image: img)
                    let xFactor = ssRect.width / activeSRect.width
                    let yFactor = ssRect.height / activeSRect.height
                    // Map this screen's sub-rect into the projected image's space
                    let sFRect = CGRect(x: (sInRect.origin.x - activeSRect.origin.x) * xFactor + ssRect.origin.x,
                                        y: (sInRect.origin.y - activeSRect.origin.y) * yFactor + ssRect.origin.y,
                                        width: sInRect.width*xFactor,
                                        height: sInRect.height*yFactor)

                    if let image = img {
                        image.draw(in: sInRect, from: sFRect, operation: NSCompositingOperation.copy, fraction: 1.0)
                    } else if !isDashboardMode {
                        errorLog("\(#file) screenshot is missing!!!")
                    }
                }
            }

            // We preserve those calculations to handle our clicking logic
            displayPreviews.append(DisplayPreview(screen: screen, previewRect: sInRect))

            // We put a white bar on the main screen
            if screen.isMain {
                let mainRect = CGRect(x: sRect.origin.x, y: sRect.origin.y + sRect.height-8, width: sRect.width, height: 8)
                let sMainPath = NSBezierPath(rect: mainRect)
                NSColor.black.setFill()
                sMainPath.fill()
                let sMainInPath = NSBezierPath(rect: mainRect.insetBy(dx: 1, dy: 1))
                NSColor.white.setFill()
                sMainInPath.fill()
            }
        }
    }

    // Helper to keep aspect ratio of screenshots to be displayed
    func calcScreenshotRect(src: CGRect) -> CGRect {
        var minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat, scaleFactor: CGFloat

        let imgw: CGFloat = 720
        let imgh: CGFloat = 400

        if (imgw/imgh) < (src.width/src.height) {
            minX = 0
            maxX = imgw
            scaleFactor = src.width / maxX
            maxY = src.height / scaleFactor
            minY = (imgh - maxY)/2
        } else {
            minY = 0
            maxY = imgh
            scaleFactor = src.height / maxY
            maxX = src.width / scaleFactor
            minX = (imgw - maxX)/2
        }

        return CGRect(x: minX, y: minY, width: maxX, height: maxY)
    }

    // MARK: - Dashboard image helpers

    /// The image to paint on an active screen. In dashboard mode this is
    /// the current video's thumbnail; otherwise the bundled stock shot
    /// `screenN.jpg` used by the Displays-settings preview.
    private func contentImage(stockIndex: Int) -> NSImage? {
        if isDashboardMode { return dashboardImage }
        if let path = Bundle.main.path(forResource: "screen" + String(stockIndex), ofType: "jpg") {
            return NSImage(contentsOfFile: path)
        }
        return nil
    }

    /// The single image projected across the span in spanned mode (current
    /// video's thumbnail in dashboard mode, else stock `screen0.jpg`).
    private func spanImage() -> NSImage? {
        if isDashboardMode { return dashboardImage }
        if let path = Bundle.main.path(forResource: "screen0", ofType: "jpg") {
            return NSImage(contentsOfFile: path)
        }
        return nil
    }

    /// Source crop rect (aspect-fill) for drawing `image` into `target`.
    /// `calcScreenshotRect` assumes the 720×400 stock shots; video
    /// thumbnails are arbitrary sizes, so dashboard mode computes the crop
    /// from the real image dimensions instead.
    private func sourceRect(forTarget target: CGRect, image: NSImage?) -> CGRect {
        guard isDashboardMode, let image = image,
              image.size.width > 0, image.size.height > 0 else {
            return calcScreenshotRect(src: target)
        }
        let imgw = image.size.width, imgh = image.size.height
        var minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat, scaleFactor: CGFloat
        if (imgw / imgh) < (target.width / target.height) {
            minX = 0; maxX = imgw
            scaleFactor = target.width / maxX
            maxY = target.height / scaleFactor
            minY = (imgh - maxY) / 2
        } else {
            minY = 0; maxY = imgh
            scaleFactor = target.height / maxY
            maxX = target.width / scaleFactor
            minX = (imgw - maxX) / 2
        }
        return CGRect(x: minX, y: minY, width: maxX, height: maxY)
    }

    // MARK: - Clicking
    override func mouseDown(with event: NSEvent) {
        let displayDetection = DisplayDetection.sharedInstance

        // Grab relative location of the click in view
        let point = convert(event.locationInWindow, from: nil)

        debugLog("DisplayView.mouseDown: point=\(point) displayMode=\(PrefsDisplays.displayMode) previews=\(displayPreviews.count)")

        // If in selection mode, toggle the screen & redraw
        if PrefsDisplays.displayMode == .selection {
            for displayPreview in displayPreviews {
                debugLog("  checking preview rect=\(displayPreview.previewRect) for screen=\(displayPreview.screen.id)")
                if displayPreview.previewRect.contains(point) {
                    if displayDetection.isScreenActive(id: displayPreview.screen.id) {
                        displayDetection.unselectScreen(id: displayPreview.screen.id)
                    } else {
                        displayDetection.selectScreen(id: displayPreview.screen.id)
                    }
                    debugLog("  -> toggled screen \(displayPreview.screen.id), calling onScreenToggled")
                    self.needsDisplay = true
                    onScreenToggled?()
                }
            }
        }
    }
}
