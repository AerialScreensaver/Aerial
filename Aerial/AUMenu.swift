//
//  AUMenu.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 25/07/2020.
//

import Cocoa

class AUMenu: NSMenu {
    
    @IBOutlet weak var installedVersion: NSTextField!
    
    override func awakeFromNib() {
        installedVersion.stringValue = "Hello there!"
    }
}
