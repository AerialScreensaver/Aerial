//
//  FirstLaunchModeStep.swift
//  Aerial Companion
//
//  Step 1 of the first-launch wizard — the three wallpaper modes
//  (off / still / live), driven by the wallpaper extension. Selection
//  lives on the parent `WizardState`; this view is presentation-only.
//

import SwiftUI

struct FirstLaunchModeStep: View {
    @ObservedObject var state: FirstLaunchWizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose how Aerial fits your setup")
                    .font(.system(size: 20, weight: .semibold))
                Text("Pick a starting point. Nothing here is permanent — every option can be changed later in Settings.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            // The three wallpaper modes are driven by the extension
            // (off / still / live).
            WallpaperModeChooser(selection: Binding(
                get: { state.wallpaperMode ?? .animated },
                set: { state.wallpaperMode = $0 }
            ))

            Spacer(minLength: 0)
        }
    }
}
