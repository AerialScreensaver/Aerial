//
//  InfoView.swift
//  Aerial Companion
//
//  Thin wrapper that hosts `AboutContent` inside the standalone "About
//  Aerial" window opened from the popover's info-circle button. The
//  shared `AboutContent` view also backs the Settings → About panel,
//  so any visual change happens in one place.
//

import SwiftUI

struct InfoView: View {
    var body: some View {
        AboutContent()
    }
}

struct InfoView_Previews: PreviewProvider {
    static var previews: some View {
        InfoView()
    }
}
