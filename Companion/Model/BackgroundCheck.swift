//
//  BackgroundCheck.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 26/07/2020.
//

import Foundation


class BackgroundCheck {
    static let instance: BackgroundCheck = BackgroundCheck()
    
    let hourSeconds = 3600
    let daySeconds = 60 * 60 * 24
    let weekSeconds = 60 * 60 * 24 * 7
    
    var timer: DispatchSourceTimer?
    
    // This is where we set our callbacks to get notified of time passed
    func set() {
        if let oldTimer = timer {
            oldTimer.suspend()
        }

        // Set the timer
        timer = DispatchSource.makeTimerSource(flags: [], queue: DispatchQueue.main)
        
        if let newTimer = timer {
            debugLog("Setting timer to: \(Preferences.checkEvery)")
            switch  Preferences.checkEvery {
            case .hour:
                newTimer.schedule(deadline: .now(), repeating: .seconds(hourSeconds))
            case .day:
                newTimer.schedule(deadline: .now(), repeating: .seconds(daySeconds))
            case .week:
                newTimer.schedule(deadline: .now(), repeating: .seconds(weekSeconds))
            }

            newTimer.setEventHandler
            {
                Update.instance.unattendedCheck()
            }
            newTimer.resume()
        }
    }
    
    func getTimer() -> Int {
        switch Preferences.checkEvery {
        case .hour:
            return hourSeconds
        case .day:
            return daySeconds
        case .week:
            return weekSeconds
        }
    }
}
