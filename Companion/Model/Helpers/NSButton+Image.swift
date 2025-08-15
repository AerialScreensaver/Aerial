//
//  NSButton+Image.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 07/07/2023.
//

import Foundation

@IBDesignable class NSButtonWithImageSpacing: NSButton {
    @IBInspectable var verticalImagePadding: CGFloat = 0
    @IBInspectable var horizontalImagePadding: CGFloat = 0
    
    override func draw(_ dirtyRect: NSRect) {
        // Reset the bounds after drawing is complete
        let originalBounds = self.bounds
        defer { self.bounds = originalBounds }

        // Inset bounds by the image padding
        self.bounds = originalBounds.insetBy(
            dx: horizontalImagePadding,
            dy: verticalImagePadding
        )

        // Draw the button content with padding
        super.draw(dirtyRect)
    }
}
