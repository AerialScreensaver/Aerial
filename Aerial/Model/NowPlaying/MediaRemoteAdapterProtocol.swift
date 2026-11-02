//
//  MediaRemoteAdapterProtocol.swift
//  Aerial
//
//  The wire format of the vendored mediaremote-adapter
//  (Vendor/mediaremote-adapter, BSD-3): one JSON object per stdout line.
//  `get` prints the now-playing dictionary once, or `null`. `stream`
//  prints `{"type":"data","diff":Bool,"payload":{…}}` on every change; in
//  diff mode a key set to `null` has been removed. Pure value code — no
//  Process, no AppKit — so it is unit-tested with fixture lines.
//

import Foundation

/// One parsed stdout line.
enum MediaRemoteAdapterLine: Equatable {
    /// A now-playing payload. `diff == false` is a full snapshot (also what
    /// a bare `get` object is treated as), `diff == true` a delta.
    case data(diff: Bool, payload: [String: Any])
    /// Nothing playing (`get` printed `null`, or a stream line whose
    /// payload is `null`).
    case null
    /// An envelope of a type this version does not know.
    case other(type: String)

    static func == (lhs: MediaRemoteAdapterLine, rhs: MediaRemoteAdapterLine) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.other(let a), .other(let b)): return a == b
        case (.data(let da, let pa), .data(let db, let pb)):
            return da == db && NSDictionary(dictionary: pa).isEqual(to: pb)
        default: return false
        }
    }

    /// nil for an empty or unparseable line (logged by the caller).
    static func parse(_ line: String) -> MediaRemoteAdapterLine? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "null" { return .null }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        guard let type = dict["type"] as? String else {
            // A bare `get` object: no envelope.
            return .data(diff: false, payload: dict)
        }
        guard type == "data" else { return .other(type: type) }
        let diff = (dict["diff"] as? Bool) ?? false
        guard let payload = dict["payload"] as? [String: Any] else { return .null }
        return .data(diff: diff, payload: payload)
    }
}

/// Folds stream lines into the current now-playing dictionary.
struct MediaRemoteStateMerger {
    private(set) var state: [String: Any] = [:]
    /// True once any line has been applied — `fetchCurrentSong` can then
    /// answer from `state` instead of spawning a `get`.
    private(set) var hasSnapshot = false

    /// Returns true when `state` changed.
    mutating func apply(_ line: MediaRemoteAdapterLine) -> Bool {
        switch line {
        case .null:
            hasSnapshot = true
            let changed = !state.isEmpty
            state = [:]
            return changed
        case .data(let diff, let payload):
            hasSnapshot = true
            if !diff {
                state = payload.filter { !($0.value is NSNull) }
                return true
            }
            var changed = false
            for (key, value) in payload {
                if value is NSNull {
                    if state.removeValue(forKey: key) != nil { changed = true }
                } else {
                    state[key] = value
                    changed = true
                }
            }
            return changed
        case .other:
            return false
        }
    }
}

/// What the overlay cares about, reduced to an equatable key so timing
/// ticks (elapsedTime/timestamp diffs) never cause an emission and an
/// unchanged artwork is never decoded twice. `nil` = nothing to show
/// (not playing, or no title), today's "paused/stopped → nil" semantics.
struct MediaRemoteSongKey: Equatable {
    let bundleID: String
    let title: String
    let artist: String
    let album: String
    /// Hash of the base64 artwork string, nil when the payload has none
    /// (artwork usually arrives in a later diff line).
    let artworkHash: Int?

    static func key(from state: [String: Any], allowPaused: Bool = false) -> MediaRemoteSongKey? {
        guard let title = state["title"] as? String, !title.isEmpty else { return nil }
        if !allowPaused {
            guard (state["playing"] as? Bool) == true else { return nil }
        }
        let artwork = state["artworkData"] as? String
        return MediaRemoteSongKey(
            bundleID: state["bundleIdentifier"] as? String ?? "",
            title: title,
            artist: state["artist"] as? String ?? "",
            album: state["album"] as? String ?? "",
            artworkHash: artwork.map { $0.hashValue }
        )
    }

    /// The raw artwork bytes for this state, if present.
    static func artworkData(from state: [String: Any]) -> Data? {
        guard let base64 = state["artworkData"] as? String, !base64.isEmpty else { return nil }
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }
}
