//
//  NSScreen+Id.swift
//  Aerial Companion
//
//  Created by Jared Furlow on 6/25/21.
//

// From https://gist.github.com/salexkidd/bcbea2372e92c6e5b04cbd7f48d9b204
extension NSScreen {
    
    public var screenUuid: String {
        get {
            return CFUUIDCreateString(nil, CGDisplayCreateUUIDFromDisplayID(deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID).takeRetainedValue()) as String
        }
    }


    public var displayName: String {
        get {
            let screenId = CGDisplayGetDisplayIDFromUUID(CFUUIDCreateFromString(nil, screenUuid as CFString))
            
            var name = "Unknown"
            var object : io_object_t
            var serialPortIterator = io_iterator_t()
            let matching = IOServiceMatching("IODisplayConnect")
            
            let kernResult = IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &serialPortIterator)
            if KERN_SUCCESS == kernResult && serialPortIterator != 0 {
                repeat {
                    object = IOIteratorNext(serialPortIterator)
                    let displayInfo = IODisplayCreateInfoDictionary(object, UInt32(kIODisplayOnlyPreferredName)).takeRetainedValue() as NSDictionary as! [String:AnyObject]
            
                    if  (displayInfo[kDisplayVendorID] as? UInt32 == CGDisplayVendorNumber(screenId) &&
                         displayInfo[kDisplayProductID] as? UInt32 == CGDisplayModelNumber(screenId) &&
                         displayInfo[kDisplaySerialNumber] as? UInt32 ?? 0 == CGDisplaySerialNumber(screenId)
                    ) {
                        if let productName = displayInfo["DisplayProductName"] as? [String:String],
                            let firstKey = Array(productName.keys).first {
                            name = productName[firstKey]!
                            break
                        }
                    }
                } while object != 0
            }
            IOObjectRelease(serialPortIterator)
            return name
        }
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
