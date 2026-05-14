//
//  NSScreen+Id.swift
//  Aerial Companion
//
//  Created by Jared Furlow on 6/25/21.
//

import AppKit

// From https://gist.github.com/salexkidd/bcbea2372e92c6e5b04cbd7f48d9b204
extension NSScreen {
    
    public var screenUuid: String {
        return CFUUIDCreateString(nil, CGDisplayCreateUUIDFromDisplayID(deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID).takeRetainedValue()) as String
    }

    static public func getScreenByUuid(_ screenUuid: String) -> NSScreen? {
        for screen in NSScreen.screens {
            if screen.screenUuid == screenUuid {
                return screen
            }
        }
        
        return nil
    }
}
