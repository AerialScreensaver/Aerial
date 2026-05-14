//
//  VideoMetadataHelpers.swift
//  Aerial Companion
//
//  Shared helpers for video metadata display (time-of-day, scene, duration).
//

import Foundation

func timeOfDayIcon(_ timeOfDay: String) -> String {
    switch timeOfDay.lowercased() {
    case "day": return "sun.max"
    case "night": return "moon.stars"
    case "sunset": return "sunset"
    case "sunrise": return "sunrise"
    default: return "sun.max"
    }
}

func sceneIcon(_ scene: SourceScene) -> String {
    switch scene {
    case .nature: return "leaf"
    case .city: return "building.2"
    case .space: return "sparkles"
    case .sea: return "water.waves"
    case .beach: return "beach.umbrella"
    case .countryside: return "mountain.2"
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    let m = total / 60
    let s = total % 60
    return "\(m):\(String(format: "%02d", s))"
}

func nextTimeSlice(_ current: String) -> String {
    switch current {
    case "night": return "sunrise"
    case "sunrise": return "day"
    case "day": return "sunset"
    case "sunset": return "night"
    default: return "day"
    }
}

func timeRemainingString(until date: Date) -> String {
    let seconds = max(0, Int(date.timeIntervalSinceNow))
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 {
        return "\(hours)h\(String(format: "%02d", minutes))"
    }
    return "\(minutes)m"
}
