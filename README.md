# Aerial (formerly Aerial Companion)

[![Total downloads](https://img.shields.io/github/downloads/AerialScreensaver/Aerial/total?style=flat-square&logo=apple&logoColor=white)](https://github.com/AerialScreensaver/Aerial/releases) [![Latest release](https://img.shields.io/github/v/release/AerialScreensaver/Aerial?style=flat-square)](https://github.com/AerialScreensaver/Aerial/releases/latest)

![Aerial screensaver showing weather, clock, and now-playing overlays atop a sunset video](screenshot.webp)

The Apple TV screensaver for your mac, now with optional wallpaper continuity. With optional overlays, time-of-day adaptation, and live camera feeds support. Now distributed as an App + App Extension.

Version 4.1 is currently available in beta with a native wallpaper extension, replacing continuity and fixing the last remaining issues.

For more details, check the website: [aerialscreensaver.github.io](https://aerialscreensaver.github.io)

## App Extension

Starting with version 4, Aerial is now distributed as an App Extension, bundled inside the Aerial.app. This is using the same private API that Apple introduced in macOS 10.15 (yes, Catalina !) but still has not made public. The App Extension API allows to provide full compatibility with Sonoma and Tahoe, sidestepping the longstanding issues with the old outdated `.saver` API and it's terrible `legacyScreenSaver.appex` "compatibility layer". 

If you want to make your own macOS App Extension screensaver, instead of messing with Aerial code (which has so much backward compatibility/legacy things), I vastly recommend you start with  [AppexSaverMinimal](https://github.com/AerialScreensaver/AppexSaverMinimal) as a much easier to understand starting point ! It's a minimal working sample, with a clear documentation of what works, what changes from the old API, and what you should adapt if you already have a `.saver` project. 

## Requirements

- macOS 15 (Sequoia) or later.
- Xcode 16 or later to build from source.

For earlier macOS Versions, check the [old saver repository](https://github.com/JohnCoates/Aerial). 

For macOS 27 Golden Gate, use the latest beta.

- If you only want the old `.saver`, [version 3.6.3](https://github.com/JohnCoates/Aerial/releases/tag/v3.6.3) is the latest available.

- If you want to use the old desktop mode from Companion, [version 1.5.3beta1](https://github.com/AerialScreensaver/Aerial/releases/download/v1.5.3beta1/Aerial.Companion.zip) is the latest : you *will need* to disable the update checks as you will be prompted to upgrade to version 4 ! It will automatically download version 3.6.3 of the `.saver` at first launch. 

## Build from source

```bash
git clone https://github.com/AerialScreensaver/Aerial.git
cd Aerial
open Aerial.xcodeproj
```

In Xcode, pick the **Aerial** scheme and build (`⌘B`) or run (`⌘R`).

Note that `ScreenSaver/Source/Models/API/APISecrets.swift` ships with a blank OpenWeather key in the public source. The weather overlay won't display data unless you put your own key. Everything else in the app works without it.

## Thank you

Weather overlays are provided thanks to [Openweather](https://openweathermap.org) who has offerred free support for Aerial for *many* years now ! Many thanks to them !

<a href="https://openweathermap.org"><img src="ScreenSaver/Resources/openweather_logo.png" alt="OpenWeather" width="200"></a>

Aerial relies on a few great open source projects, you should check them out : 
- [Sparkle](https://sparkle-project.org) for auto-updates
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus for global shortcuts handling
- [Github releases to discord](https://github.com/SethCohen/github-releases-to-discord) by Seth Cohen for release notes in the community Discord
- [Swift Argument parser](https://github.com/apple/swift-argument-parser) by Apple (not used directly by Aerial, but [PaperSaver](https://github.com/AerialScreensaver/PaperSaver) does use it)

Many thanks to those maintainers and their contributors !

To enable the screensaver (and wallpaper in version 4.1), Aerial relies on [PaperSaver](https://github.com/AerialScreensaver/PaperSaver). You can use this library to set your own screensaver too as the old API is no longer available to do this, and Apple does not provide a replacement.

## Contributing

Contributions welcome, but **please open an issue first** for substantial changes so we can discuss the approach before you put time into it.

## License

MIT — see [LICENSE](LICENSE).
