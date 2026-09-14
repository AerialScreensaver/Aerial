//
//  PrefsAdvanced.swift
//  Aerial
//
//  Created by Guillaume Louel on 23/04/2020.
//  Copyright © 2020 Guillaume Louel. All rights reserved.
//

import Foundation

/// Which overlap workaround the extension applies while diagnostic
/// badges are on (a literal manual override). `variantD`
/// (contents-swap: no AVSampleBufferDisplayLayer in the tree) is the
/// production default; `variantA` (plain AVSBDL sublayer) is the only
/// construction with an EDR/HDR path and is auto-selected off-badges
/// when the video format is HDR. Raw values are historical — 0=random,
/// 2=B and 3=C were retired 2026-07; the failable init plus the
/// `?? .variantD` fallback absorbs stale stored values.
enum OverlapWorkaround: Int {
    case variantA = 1
    case variantD = 4
}

struct PrefsAdvanced {
    // MARK: - Settings Manager

    private static let manager = ScreensaverSettingsManager.shared

    // MARK: - Advanced Settings

    // (muteSound / muteGlobalSound accessors removed 2026-07: audio is
    // now a live WallpaperControlState setting. The struct fields stay
    // in AdvancedSettings for file compatibility — its decoder is
    // non-optional.)

    static var favorOrientation: Bool {
        get { manager.getValue(forKeyPath: \.advanced.favorOrientation) }
        set { manager.setValue(newValue, forKeyPath: \.advanced.favorOrientation) }
    }

    static var debugMode: Bool {
        get { manager.getValue(forKeyPath: \.advanced.debugMode) }
        set { manager.setValue(newValue, forKeyPath: \.advanced.debugMode) }
    }

    static var ciOverrideLanguage: String {
        get { manager.getValue(forKeyPath: \.advanced.ciOverrideLanguage) }
        set { manager.setValue(newValue, forKeyPath: \.advanced.ciOverrideLanguage) }
    }

    static var newDisplayDict: [String: Bool] {
        get { manager.getValue(forKeyPath: \.advanced.newDisplayDict) }
        set { manager.setValue(newValue, forKeyPath: \.advanced.newDisplayDict) }
    }

    static var showDiagnosticBadges: Bool {
        get { manager.getValue(forKeyPath: \.advanced.showDiagnosticBadges) }
        set { manager.setValue(newValue, forKeyPath: \.advanced.showDiagnosticBadges) }
    }

    static var overlapWorkaround: OverlapWorkaround {
        get { OverlapWorkaround(rawValue: manager.getValue(forKeyPath: \.advanced.intOverlapWorkaround)) ?? .variantD }
        set { manager.setValue(newValue.rawValue, forKeyPath: \.advanced.intOverlapWorkaround) }
    }
}
