//
//  ScreenThumbnailView.swift
//  Aerial Companion
//
//  A miniature of a single display at its true aspect ratio, showing that
//  screen's currently-selected video. Used by independent-mode Dashboard
//  cards. Inactive displays (excluded by the current Display Mode) render
//  as a dimmed "not playing" tile.
//

import SwiftUI

struct ScreenThumbnailView: View {
    /// width / height of the physical display.
    let aspect: CGFloat
    let isMain: Bool
    let isActive: Bool
    let thumbnail: NSImage?

    var maxWidth: CGFloat = 200
    var maxHeight: CGFloat = 120

    /// Concrete size that fits the display's aspect ratio inside the box.
    private var fitted: CGSize {
        let a = aspect > 0 ? aspect : (16.0 / 9.0)
        let boxAspect = maxWidth / maxHeight
        if a >= boxAspect {
            return CGSize(width: maxWidth, height: maxWidth / a)
        } else {
            return CGSize(width: maxHeight * a, height: maxHeight)
        }
    }

    var body: some View {
        ZStack {
            if isActive, let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: fitted.width, height: fitted.height)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.black.opacity(isActive ? 0.8 : 0.55))
                    .overlay(
                        Image(systemName: isActive ? "photo" : "display.trianglebadge.exclamationmark")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                    )
            }
        }
        .frame(width: fitted.width, height: fitted.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.black.opacity(0.35), lineWidth: 1)
        )
        .overlay(alignment: .top) {
            // Evokes the menubar on the primary display.
            if isMain {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.85))
                    .frame(width: fitted.width * 0.45, height: 3)
                    .padding(.top, 3)
            }
        }
        .opacity(isActive ? 1.0 : 0.85)
    }
}
