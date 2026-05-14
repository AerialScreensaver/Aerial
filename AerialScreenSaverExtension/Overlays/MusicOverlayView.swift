//
//  MusicOverlayView.swift
//  AerialScreenSaverExtension
//
//  SwiftUI overlay displaying now-playing music information.
//

import SwiftUI

struct MusicOverlayView: View {
    let songInfo: SongInfo?
    let fontSize: Double
    let fontName: String

    var body: some View {
        guard let song = songInfo, !song.name.isEmpty else {
            return AnyView(EmptyView())
        }

        return AnyView(
            HStack(alignment: .center, spacing: fontSize * 0.3) {
                // Album artwork or fallback icon
                Group {
                    if let artwork = song.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "music.note")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .frame(width: fontSize * 2.5, height: fontSize * 2.5)

                // Song details
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name)
                        .font(musicFont(size: fontSize))

                    if !song.artist.isEmpty {
                        Text(song.artist)
                            .font(musicFont(size: fontSize * 0.7))
                            .opacity(0.85)
                    }

                    if !song.album.isEmpty {
                        Text(song.album)
                            .font(musicFont(size: fontSize * 0.6))
                            .opacity(0.7)
                    }
                }
            }
        )
    }

    private func musicFont(size: Double) -> Font {
        if fontName == "system" {
            return .system(size: size, weight: .medium)
        }
        return .custom(fontName, size: size)
    }
}
