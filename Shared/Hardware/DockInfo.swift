//
//  DockInfo.swift
//  Aerial Companion
//
//  Detects the macOS Dock's edge and thickness for a given NSScreen
//  by diffing screen.frame and screen.visibleFrame.
//  When autohide is on, visibleFrame == frame so edge is .none.
//

import AppKit
import SwiftUI

struct DockInfo: Equatable {
    enum Edge: String {
        case bottom, left, right, none
    }

    var edge: Edge
    var thickness: CGFloat   // height if bottom, width if left/right; 0 if none
    /// Menu bar height (the screen's top inset); 0 when hidden. Measured
    /// independently of the dock — both can inset the same screen.
    var menuBar: CGFloat = 0

    static let none = DockInfo(edge: .none, thickness: 0, menuBar: 0)

    /// Detect the Dock and menu bar from the difference between the
    /// screen's frame and visibleFrame. The dock edge is `.none` if the
    /// dock is autohidden, on a different screen, or absent; `menuBar`
    /// is measured either way.
    static func detect(for screen: NSScreen) -> DockInfo {
        let f = screen.frame
        let v = screen.visibleFrame
        let bottom = v.minY - f.minY
        let left   = v.minX - f.minX
        let right  = f.maxX - v.maxX
        let top    = f.maxY - v.maxY
        // Use a 1pt threshold to ignore subpixel rounding noise.
        let menuBar = top > 1 ? top : 0
        if bottom > 1 { return DockInfo(edge: .bottom, thickness: bottom, menuBar: menuBar) }
        if left > 1 { return DockInfo(edge: .left, thickness: left, menuBar: menuBar) }
        if right > 1 { return DockInfo(edge: .right, thickness: right, menuBar: menuBar) }
        return DockInfo(edge: .none, thickness: 0, menuBar: menuBar)
    }

    /// Convert this dock info into SwiftUI EdgeInsets.
    var swiftUIInsets: EdgeInsets {
        var insets = EdgeInsets(top: menuBar, leading: 0, bottom: 0, trailing: 0)
        switch edge {
        case .bottom: insets.bottom = thickness
        case .left:   insets.leading = thickness
        case .right:  insets.trailing = thickness
        case .none:   break
        }
        return insets
    }
}
