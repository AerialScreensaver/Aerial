//
//  AboutSettingsPanel.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 13/02/2026.
//

import SwiftUI

struct AboutSettingsPanel: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                Text("About")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)

                // About Aerial section — single source of truth lives
                // in `AboutContent`, also used by the standalone About
                // window (`InfoView`). Centered inside the GroupBox so
                // the fixed-width content sits nicely in the panel.
                GroupBox {
                    HStack {
                        Spacer()
                        AboutContent()
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } label: {
                    Label("About Aerial", systemImage: "airplane").font(Font.title3.bold()).padding(4)
                }

                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Preview

struct AboutSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        AboutSettingsPanel()
            .frame(width: 500, height: 600)
    }
}
