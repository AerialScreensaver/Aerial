//
//  AerialCompanionApp.swift
//  Aerial Companion
//
//  Created by SwiftUI Migration on 18/08/2024.
//

import SwiftUI

@main
struct AerialCompanionApp: App {
    // Preserve all existing AppDelegate functionality
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // Empty Settings scene - AppDelegate handles all UI for now
        Settings {
            EmptyView()
        }
    }
}