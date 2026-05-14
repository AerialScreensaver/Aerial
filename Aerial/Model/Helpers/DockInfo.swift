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

    static let none = DockInfo(edge: .none, thickness: 0)

    /// Detect the Dock from the difference between the screen's frame and visibleFrame.
    /// Returns `.none` if the dock is autohidden, on a different screen, or absent.
    static func detect(for screen: NSScreen) -> DockInfo {
        let f = screen.frame
        let v = screen.visibleFrame
        let bottom = v.minY - f.minY
        let left   = v.minX - f.minX
        let right  = f.maxX - v.maxX
        // Use a 1pt threshold to ignore subpixel rounding noise.
        if bottom > 1 { return DockInfo(edge: .bottom, thickness: bottom) }
        if left > 1 { return DockInfo(edge: .left, thickness: left) }
        if right > 1 { return DockInfo(edge: .right, thickness: right) }
        return .none
    }

    /// Convert this dock info into SwiftUI EdgeInsets.
    var swiftUIInsets: EdgeInsets {
        switch edge {
        case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: thickness, trailing: 0)
        case .left:   return EdgeInsets(top: 0, leading: thickness, bottom: 0, trailing: 0)
        case .right:  return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: thickness)
        case .none:   return EdgeInsets()
        }
    }
}
