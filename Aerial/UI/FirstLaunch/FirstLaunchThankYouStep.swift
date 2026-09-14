//
//  FirstLaunchThankYouStep.swift
//  Aerial Companion
//
//  Final step of the wizard: heading at the top, three-paragraph body
//  on the left, and a popover preview screenshot on the right so the
//  user sees what they're about to land on once they hit Get Started.
//

import SwiftUI

struct FirstLaunchThankYouStep: View {

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "heart.fill")
                    .foregroundColor(.pink)
                Text("Thank you for installing Aerial 4 !")
            }
            .font(.system(size: 25, weight: .semibold))

            HStack(alignment: .top, spacing: 24) {
                bodyText
                    .frame(maxWidth: .infinity, alignment: .leading)

                popoverPreview
            }.padding(.top, 24)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 24)
    }

    private var bodyText: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(.init("Aerial 4 is configured. Press *Get Started* to head into the app, it will show up in your menu bar. You can pick and control what should play directly from the menu bar, or launch the wallpaper mode from there !"))
            Text(.init("I **strongly** recommend you check the settings first (bottom left of the menu). While similar in many ways to the previous version, many features have been entirely rethought/adapted and will need to be adjusted again to your liking."))
            Text(.init("Then head to the Video Library to check more of the new features, including new high quality videos in 4K 240 fps !"))
            Text(.init("Aerial is still free and open source. If you enjoy it, check out the about box for more information on how you can support it's development."))

        }
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var popoverPreview: some View {
        Image("FirstLaunchPopoverPreview")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 240)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 2)
            .accessibilityLabel("Aerial menu bar popover preview")
    }
}
