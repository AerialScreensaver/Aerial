//
//  DarkMode.swift
//  Aerial
//
//  Created by Guillaume Louel on 19/12/2019.
//  Copyright © 2019 Guillaume Louel. All rights reserved.
//

import Foundation
import Cocoa

struct DarkMode {
    static func isEnabled() -> Bool {
        return Aerial.helper.darkMode
    }
}
