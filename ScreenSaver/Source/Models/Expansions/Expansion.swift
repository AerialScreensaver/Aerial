//
//  Expansion.swift
//  Aerial
//
//  Data model for the Video Library's "Expansions" page. An Expansion
//  is a curated reference to a third-party video pack (free or paid)
//  that the user can install into Aerial. The actual installation
//  goes through the existing custom-source plumbing
//  (`SourceList.fetchOnlineManifest(url:)`); this model just describes
//  the showcase entry.
//
//  Bundled JSON drives the catalog today; the same shape works for a
//  remote-fetched catalog tomorrow without UI changes.
//

import Foundation

struct Expansion: Codable, Identifiable, Hashable {
    /// Stable identifier — used as the `Identifiable` key and as the
    /// thumbnail cache key. Choose a slug, not a UUID, so JSON edits
    /// remain readable in source control.
    let id: String

    /// Display title.
    let name: String

    /// Display author / studio.
    let author: String

    /// Marketing copy shown beneath the title (2-3 lines clamped in UI).
    let description: String

    /// Hero screenshot URL (any reasonable resolution; the UI scales to
    /// a 16:9 box).
    let screenshotURL: String

    /// "Visit site" target, opened in the user's default browser.
    let websiteURL: String

    /// Manifest URL we hand to `SourceList.fetchOnlineManifest(url:)`
    /// when the user clicks Install. nil for paid packs whose URL is
    /// per-customer (the user pastes their personal install link via
    /// the "Got an install link?" sheet after purchase).
    let manifestURL: String?

    /// Source name to match against `SourceList.list[…].name` for the
    /// "is this expansion installed?" predicate. Must match exactly
    /// the name that the manifest declares once installed.
    let sourceName: String

    /// `.free` packs get a one-click Install button; `.paid` packs
    /// only get Visit site (no prices shown in-app).
    let tier: Tier

    /// Optional. When `true`, the card surfaces a "240 FPS" pill next
    /// to the tier badge. Absent / `false` for normal-framerate packs.
    let is240fps: Bool?

    /// Stripped asset list for the pack — same shape as the live
    /// `entries.json` minus every `url*` key. Drives global search
    /// for expansions that are NOT yet installed so users can find
    /// videos that live in packs they haven't downloaded. `nil` on
    /// older catalog revisions or paid packs whose contents we don't
    /// publish.
    let assets: [ExpansionAsset]?

    enum Tier: String, Codable {
        case free
        case paid
    }
}

/// One video's worth of metadata pulled from a pack's `entries.json`
/// with every video-download URL stripped. Only `previewImage`
/// remains as a link (the thumbnail). Used as the search source of
/// truth for not-yet-installed expansions.
struct ExpansionAsset: Codable, Hashable, Identifiable {
    let id: String
    let title: String?
    let accessibilityLabel: String?
    let scene: String?
    let timeOfDay: String?
    let pointsOfInterest: [String: String]?
    let previewImage: String?
}

struct ExpansionCatalog: Codable {
    let version: Int
    let expansions: [Expansion]
}
