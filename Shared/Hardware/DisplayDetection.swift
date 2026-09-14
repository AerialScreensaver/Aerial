//
//  DisplayDetection.swift
//  Aerial
//
//  Created by Guillaume Louel on 09/05/2019.
//  Copyright © 2019 John Coates. All rights reserved.
//

import Foundation
import Cocoa

class Screen: NSObject {
    var id: CGDirectDisplayID
    var width: Int
    var height: Int
    var bottomLeftFrame: CGRect
    var topRightCorner: CGPoint
    var zeroedOrigin: CGPoint
    var isMain: Bool
    var backingScaleFactor: CGFloat

    init(id: CGDirectDisplayID, width: Int, height: Int, bottomLeftFrame: CGRect, isMain: Bool, backingScaleFactor: CGFloat) {
        self.id = id
        self.width = width
        self.height = height
        self.bottomLeftFrame = bottomLeftFrame
        // We precalculate the right corner too, as we will need this !
        self.topRightCorner = CGPoint(x: bottomLeftFrame.origin.x + CGFloat(width),
                                      y: bottomLeftFrame.origin.y + CGFloat(height))
        self.zeroedOrigin = CGPoint(x: 0, y: 0)
        self.isMain = isMain
        self.backingScaleFactor = backingScaleFactor
    }

    override var description: String {
        return "[id=\(self.id), width=\(self.width), height=\(self.height), bottomLeftFrame=\(self.bottomLeftFrame), topRightCorner=\(self.topRightCorner), isMain=\(self.isMain), backingScaleFactor=\(self.backingScaleFactor)]"
    }
}

// swiftlint:disable:next type_body_length
final class DisplayDetection: NSObject {
    static let sharedInstance = DisplayDetection()

    /// Enumerate displays through CoreGraphics instead of `NSScreen`.
    /// The wallpaper appex sets this at launch: an ExtensionFoundation
    /// appex has no NSApplication run loop, so `NSScreen.screens` is
    /// frozen at first access — a display attached after the process
    /// started (a DisplayLink monitor showing up seconds after boot or
    /// wake, often under a NEW display id) is never listed, every
    /// spanned lookup for it fails ("screen NOT FOUND") and it falls
    /// back to a centre-cropped per-display frame while the other
    /// windows keep the stale canvas (2026-08-22 four-display bundle).
    /// CG display lists are live in any process. Companion keeps
    /// NSScreen (it has the run loop; both agree there).
    nonisolated(unsafe) static var useCoreGraphicsEnumeration = false   // set once at appex init, before first use

    var screens = [Screen]()
    var unusedScreens = [Screen]()

    var cmInPoints: CGFloat = 40
    var maxLeftScreens: CGFloat = 0
    var maxBelowScreens: CGFloat = 0

    var advancedScreenRect: CGRect?
    var advancedZeroedScreenRect: CGRect?

    // MARK: - Lifecycle
    override init() {
        super.init()
        debugLog("📺 Display Detection initialized")
        detectDisplays()
    }

    // MARK: - Detection
    func detectDisplays() {
        // Display detection is done in two passes :
        // - Through CGDisplay, we grab all online screens (connected, but
        //   may or may not be powered on !) and get most information needed
        // - Through NSScreen to get the backingScaleFactor (retinaness of a screen)

        // Cleanup a bit in case of redetection
        screens = [Screen]()
        maxLeftScreens = 0
        maxBelowScreens = 0

        // First pass
        let maxDisplays: UInt32 = 32
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0

        _ = CGGetOnlineDisplayList(maxDisplays, &onlineDisplays, &displayCount)
        var mainID: CGDirectDisplayID?

        for currentDisplay in onlineDisplays[0..<Int(displayCount)] {
            let isMain = CGDisplayIsMain(currentDisplay)

            if isMain == 1 {
                // We calculate the equivalent of a centimeter in points on the main screen as a reference
                let mmsize = CGDisplayScreenSize(currentDisplay)
                let wide = CGDisplayPixelsWide(currentDisplay)
                // DisplayLink virtual displays (and any display caught
                // mid-detach) report a ZERO physical size — the division
                // then poisons `cmInPoints` with ∞/NaN. The value is
                // sticky and flows through the spanned margins into every
                // layer frame; CALayer throws on a non-finite position
                // and aborts the process (2026-08-28 field crash inside
                // the control-reconcile re-slice). Keep the previous
                // value (default 40) instead.
                if mmsize.width > 0, wide > 0 {
                    cmInPoints = CGFloat(wide) / CGFloat(mmsize.width) * 10
                } else {
                    debugLog("📺 main display \(currentDisplay) reports no physical size (\(mmsize)) — keeping cmInPoints=\(cmInPoints)")
                }
                mainID = currentDisplay
            }
        }

        // Second pass: build the screen list. NSScreen hands us the
        // Cocoa frame + backing scale directly; the CoreGraphics path
        // (appex — see `useCoreGraphicsEnumeration`) derives the same
        // `Screen` shape from live CG calls.
        if DisplayDetection.useCoreGraphicsEnumeration {
            screens = DisplayDetection.enumerateViaCoreGraphics(mainID: mainID)
        } else {
            for screen in NSScreen.screens {
                let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

                var thisIsMain = false
                if screenID == mainID {
                    thisIsMain = true
                }

                screens.append(Screen(id: screenID,
                                      width: Int(screen.frame.width),
                                      height: Int(screen.frame.height),
                                      bottomLeftFrame: screen.frame,
                                      isMain: thisIsMain,
                                      backingScaleFactor: screen.backingScaleFactor))
            }
        }

        // Before we finish, we calculate the origin of each screen from a 0,0 perspective
        // This calculation is pretty different in advanced mode so it got split up
        if PrefsDisplays.displayMarginsAdvanced && !advancedMargins.displays.isEmpty {
            calculateAdvancedZeroedOrigins()
        } else {
            calculateZeroedOrigins()
        }

        for screen in screens {
            debugLog("📺 found \(screen)")
        }

        // We store the list to pluck it later
        unusedScreens = screens
        
        debugLog("\(getGlobalScreenRect())")
    }

    // MARK: - CoreGraphics enumeration (appex)

    /// Live display list from CoreGraphics, shaped like the NSScreen
    /// pass: Cocoa bottom-left frames relative to the main display,
    /// main first, mirror secondaries skipped (NSScreen lists only the
    /// primary of a mirror set). Scale = mode pixel width / point width.
    static func enumerateViaCoreGraphics(mainID: CGDirectDisplayID?) -> [Screen] {
        let maxDisplays: UInt32 = 32
        var active = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(maxDisplays, &active, &count) == .success else {
            errorLog("📺 CGGetActiveDisplayList failed — no displays enumerated")
            return []
        }
        let ids = Array(active[0..<Int(count)]).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        let main = mainID ?? CGMainDisplayID()
        let mainHeight = CGDisplayBounds(main).height

        var ordered = ids.filter { $0 != main }
        if ids.contains(main) { ordered.insert(main, at: 0) }

        var result: [Screen] = []
        for did in ordered {
            let cocoa = cocoaFrame(fromCGBounds: CGDisplayBounds(did), mainHeight: mainHeight)
            var scale: CGFloat = 1.0
            if let mode = CGDisplayCopyDisplayMode(did), mode.width > 0 {
                scale = CGFloat(mode.pixelWidth) / CGFloat(mode.width)
            }
            result.append(Screen(id: did,
                                 width: Int(cocoa.width),
                                 height: Int(cocoa.height),
                                 bottomLeftFrame: cocoa,
                                 isMain: did == main,
                                 backingScaleFactor: scale))
        }
        debugLog("📺 enumerated via CoreGraphics: \(result.count) active display(s)")
        return result
    }

    /// CG global bounds (top-left origin, y down, main display at 0,0)
    /// → Cocoa global frame (bottom-left origin, y up, main at 0,0):
    /// x is shared, y flips about the main display's height.
    static func cocoaFrame(fromCGBounds cg: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: cg.minX, y: mainHeight - cg.maxY, width: cg.width, height: cg.height)
    }

    /// Order-independent fingerprint of a display set (id + Cocoa frame
    /// + scale). The wallpaper extension compares it across acquires /
    /// invalidates / wakes to decide whether a spanned re-slice is due —
    /// a display re-numbered after sleep (DisplayLink) counts as a change.
    static func topologySignature(of screens: [Screen]) -> String {
        screens
            .map { s -> String in
                let f = s.bottomLeftFrame
                return "\(s.id):\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))@\(s.backingScaleFactor)"
            }
            .sorted()
            .joined(separator: "|")
    }

    /// Fingerprint of the currently detected displays.
    var topologySignature: String { DisplayDetection.topologySignature(of: screens) }

    func getScreenCount() -> Int {
        var count = 0
        for screen in screens where screen.height > 200 {
            count += 1
        }

        return count
    }

    // MARK: - Helpers
    // Regular calculation
    func calculateZeroedOrigins() {
        let orect = getGlobalScreenRect()

        for screen in screens {
            let (leftScreens, belowScreens) = detectBorders(forScreen: screen)

            if leftScreens > maxLeftScreens {
                maxLeftScreens = leftScreens
            }
            if belowScreens > maxBelowScreens {
                maxBelowScreens = belowScreens
            }

            screen.zeroedOrigin = SpannedGeometry.zeroedOrigin(
                frame: screen.bottomLeftFrame,
                globalOrigin: orect.origin,
                borders: (leftScreens, belowScreens),
                leftMargin: leftMargin(),
                belowMargin: belowMargin()
            )
        }
    }

    // Advanced calculation, this is a bit messy...
    func calculateAdvancedZeroedOrigins() {
        // 2 pass, first we calculate the real position of each screen with offsets applied
        for screen in screens {
            debugLog("Asrc orig : \(screen.bottomLeftFrame.origin)")
            var offsetleft: CGFloat = 0
            var offsettop: CGFloat = 0

            if let display = findDisplayAdvancedMargins(posx: screen.bottomLeftFrame.origin.x, posy: screen.bottomLeftFrame.origin.y) {
                offsetleft = display.offsetleft
                offsettop = display.offsettop
            }

            // These are NOT zeroed at this point !!!
            screen.zeroedOrigin = CGPoint(x: screen.bottomLeftFrame.origin.x + (offsetleft * cmInPoints),
                                          y: screen.bottomLeftFrame.origin.y + (offsettop * cmInPoints))
        }

        // We get an intermediate representation of whole bunch, non zeroed
        let irect = getIntermediateAdvancedScreenRect()
        advancedScreenRect = irect  // We store this for later...
        // And now we zero them !
        for screen in screens {
            screen.zeroedOrigin = CGPoint(x: screen.zeroedOrigin.x - irect.origin.x,
                                          y: screen.zeroedOrigin.y - irect.origin.y)
            debugLog("Zorig : \(screen.zeroedOrigin)")
        }

        // Now that zeroed is really zeroed, we can cheat a bit
        let i0rect = getIntermediateAdvancedScreenRect()
        advancedZeroedScreenRect = i0rect  // We store this for later...

        let orect = getGlobalScreenRect()
        debugLog("Orect : \(orect)")
    }

    // Border detection
    // This will work for most cases, but will fail in some grid/tetris like arrangements
    func detectBorders(forScreen: Screen) -> (CGFloat, CGFloat) {
        guard let index = screens.firstIndex(where: { $0 === forScreen }) else {
            return (0, 0)
        }
        return SpannedGeometry.borderCounts(for: index, frames: screens.map(\.bottomLeftFrame))
    }

    func leftMargin() -> CGFloat {
        return cmInPoints * CGFloat(PrefsDisplays.horizontalMargin)
    }

    func belowMargin() -> CGFloat {
        return cmInPoints * CGFloat(PrefsDisplays.verticalMargin)
    }

    func findScreenWith(frame: CGRect) -> Screen? {
        for screen in screens where frame == screen.bottomLeftFrame {
            return screen
        }

        return nil
    }
    
    func alternateFindScreenWith(frame: CGRect) -> Screen? {
        debugLog("📺☢️ fs : \(frame.size.debugDescription)")
        // This is a really simple workaround, we look at the size only, and with the screen list in reverse which seems to kindaaaa match ?
        // We temporarily ignore bsf as we may not be able to access view.window this early it seems

        debugLog("📺☢️ s \(screens.count) us \(unusedScreens.count)")
        
        for i in (0 ..< unusedScreens.count).reversed() {
            if unusedScreens[i].bottomLeftFrame.size == frame.size {
                let foundScreen = unusedScreens[i]
                unusedScreens.remove(at: i)
                debugLog("foundScreen : \(foundScreen.bottomLeftFrame.debugDescription)")
                return foundScreen
            }
        }
        
        return nil
    }


    func findScreenWith(id: CGDirectDisplayID) -> Screen? {
        for screen in screens where screen.id == id {
            return screen
        }

        return nil
    }

    /// Find the screen whose `bottomLeftFrame` (global coordinates) contains
    /// `p`. Disambiguates which screen a view is on when its local frame
    /// can't tell us which (typically two
    /// same-sized displays — the view's frame is `(0, 0, w, h)` for both).
    /// Pass the window's `frame.midX/midY` so a window flush against a
    /// boundary (origin exactly on the seam) still resolves to one side.
    func findScreenContaining(globalPoint p: CGPoint) -> Screen? {
        for screen in screens where screen.bottomLeftFrame.contains(p) {
            return screen
        }
        return nil
    }

    func markScreenAsUsed(id: CGDirectDisplayID) {
        // remove the screen from the unused list
        let filteredScreens = unusedScreens.filter { $0.id != id }
        unusedScreens = filteredScreens
    }

    // Calculate the size of the global screen (the composite of all the displays attached)
    func getGlobalScreenRect() -> CGRect {
        if PrefsDisplays.displayMarginsAdvanced && !advancedMargins.displays.isEmpty, let adv = advancedScreenRect {
            // Now this is awkward... we precalculated this at detectdisplays->advancedZeroedOrigins
            return adv
        } else {
            let bounds = SpannedGeometry.boundingRect(frames: screens.map(\.bottomLeftFrame))
            return CGRect(x: bounds.origin.x, y: bounds.origin.y,
                          width: bounds.width + (maxLeftScreens * leftMargin()),
                          height: bounds.height + (maxBelowScreens * belowMargin()))
        }
    }

    func getIntermediateAdvancedScreenRect() -> CGRect {
        // At this point, this is non zeroed
        var minX: CGFloat = 0.0, minY: CGFloat = 0.0, maxX: CGFloat = 0.0, maxY: CGFloat = 0.0
        for screen in screens {
            if screen.zeroedOrigin.x < minX {
                minX = screen.zeroedOrigin.x
            }
            if screen.zeroedOrigin.y < minY {
                minY = screen.zeroedOrigin.y
            }
            if (screen.zeroedOrigin.x + CGFloat(screen.width)) > maxX {
                maxX = screen.zeroedOrigin.x + CGFloat(screen.width)
            }
            if (screen.zeroedOrigin.y + CGFloat(screen.height)) > maxY {
                maxY = screen.zeroedOrigin.y + CGFloat(screen.height)
            }
        }

        return CGRect(x: minX, y: minY, width: maxX-minX, height: maxY-minY)
    }

    func getZeroedActiveSpannedRect() -> CGRect {
        if PrefsDisplays.displayMarginsAdvanced && !advancedMargins.displays.isEmpty, let advz = advancedZeroedScreenRect {
            // Now this is awkward... we precalculated this at detectdisplays->advancedZeroedOrigins
            return advz
        } else {
            return SpannedGeometry.spannedCanvas(
                activeFrames: screens.filter { isScreenActive(id: $0.id) }.map(\.bottomLeftFrame),
                globalOrigin: getGlobalScreenRect().origin,
                widthMargin: maxLeftScreens * leftMargin(),
                heightMargin: maxBelowScreens * belowMargin()
            )
        }
    }

    // MARK: - Public utility fuctions

    func isScreenActive(id: CGDirectDisplayID) -> Bool {
        let screen = findScreenWith(id: id)
        debugLog("ISA : \(String(describing: screen))")
        
        switch PrefsDisplays.displayMode {
        case .allDisplays:
            // This one is easy
            return true
        case .mainOnly:
            if let scr = screen {
                if scr.isMain {
                    return true
                }
            }
            return false
        case .secondaryOnly:
            if getScreenCount() > 1 {
                if let scr = screen {
                    if scr.isMain {
                        return false
                    }
                }
            }
            return true
        case .selection:
            if isScreenSelected(id: id) {
                return true
            }
            return false
        }
    }

    func isScreenSelected(id: CGDirectDisplayID) -> Bool {
        // If we have it in the dictionnary, then return that
        if PrefsAdvanced.newDisplayDict.keys.contains(String(id)) {
            return PrefsAdvanced.newDisplayDict[String(id)]!
        }
        return false    // Unknown screens will not be considered selected
    }

    func selectScreen(id: CGDirectDisplayID) {
        PrefsAdvanced.newDisplayDict[String(id)] = true
    }

    func unselectScreen(id: CGDirectDisplayID) {
        PrefsAdvanced.newDisplayDict[String(id)] = false
    }

    func findDisplayAdvancedMargins(posx: CGFloat, posy: CGFloat) -> DisplayAdvancedMargin? {
        for display in advancedMargins.displays {
            if posx == display.zleft && posy == display.ztop {
                return display
            }
        }

        return nil
    }

    var advancedMargins: AdvancedMargin {
        get {
            let jsonString = PrefsDisplays.advancedMargins

            // Empty = never configured — not a decode error worth logging.
            if !jsonString.isEmpty, let jsonData = jsonString.data(using: .utf8) {
                let decoder = JSONDecoder()

                do {
                    let adv = try decoder.decode(AdvancedMargin.self, from: jsonData)
                    return adv
                } catch {
                    // Also hit by strings from the pre-4.1 raw text field
                    // (comma format) — they were never parseable; the
                    // per-display UI rewrites them on first use.
                    errorLog("advancedMargins: \(error.localizedDescription)")
                }
            }
            return AdvancedMargin(displays: [DisplayAdvancedMargin]())
        }
        set {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted

            do {
                let jsonData = try encoder.encode(newValue)
                if let jsonString = String(data: jsonData, encoding: .utf8) {
                    PrefsDisplays.advancedMargins = jsonString
                }
            } catch {
                errorLog(error.localizedDescription)
            }
        }
    }
}

struct AdvancedMargin: Codable, Equatable {
    let displays: [DisplayAdvancedMargin]
}

/// Per-display spanned-mode offset. A display is identified by its
/// global-frame origin (`zleft`/`ztop` — matched against
/// `Screen.bottomLeftFrame.origin` in `findDisplayAdvancedMargins`);
/// `offsetleft`/`offsettop` shift that display's slice of the spanned
/// canvas, in centimeters (converted via `cmInPoints`). Written by the
/// per-display margins UI in DisplaysSettingsPanel.
struct DisplayAdvancedMargin: Codable, Equatable {
    var zleft: CGFloat
    var ztop: CGFloat
    var offsetleft: CGFloat
    var offsettop: CGFloat
}
