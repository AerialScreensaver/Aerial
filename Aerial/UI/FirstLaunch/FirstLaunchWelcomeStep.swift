//
//  FirstLaunchWelcomeStep.swift
//  Aerial Companion
//
//  First step of the first-launch wizard. Explains the upcoming macOS
//  file-access prompt and gives the user two choices: Skip (don't probe
//  the legacy Aerial container at all) or Go ahead (probe, which will
//  trigger the OS prompt). The probe is gated here so users never see
//  a permission alert before any Aerial UI has been shown.
//

import SwiftUI

struct FirstLaunchWelcomeStep: View {
    @ObservedObject var state: FirstLaunchWizardState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(.aerial)

            VStack(spacing: 18) {
                Text("Welcome to Aerial 4")
                    .font(.system(size: 36, weight: .semibold))
                VStack(spacing: 13) {
                    Text("Aerial 4 can look for old files from previous versions for migration and/or cleanup. macOS will ask you to give permission for this. I **highly recommend** you do if you used a previous version.")
                }
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 650)
            
                Text("Privacy and permissions")
                    .font(.system(size: 20, weight: .semibold)).foregroundColor(.primary)
                VStack(spacing: 13) {
                    Text("Aerial 4 doesn't collect **any** telemetry or data of any kind. In order to work *locally*, some optional features will ask for system a permission, but **always** provide an alternative :")
                    Text("- **Location Services** : Aerial can use your position to show Weather forecasts, and to calculate your local sunset/sunrise times to adapt the content that plays.")
                    Text("- **Access to macOS Wallpaper cache** : a bug in macOS Sonoma and Tahoe  makes them indefinitely keep a raw uncompressed copy of every wallpaper you ever set. If you use the Wallpaper continuity feature, it's **highly recommended** you let Aerial clean that cache for you.")
                }
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 650)
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button("Skip") {
                    state.advanceFromWelcome(probe: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Go ahead") {
                    state.advanceFromWelcome(probe: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 16)
    }
}
