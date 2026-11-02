# Aerial 4

[![Total downloads](https://img.shields.io/github/downloads/AerialScreensaver/Aerial/total?style=flat-square&logo=apple&logoColor=white)](https://github.com/AerialScreensaver/Aerial/releases) [![Latest release](https://img.shields.io/github/v/release/AerialScreensaver/Aerial?style=flat-square)](https://github.com/AerialScreensaver/Aerial/releases/latest)

![Aerial screensaver showing weather, clock, and now-playing overlays atop a sunset video](screenshot.webp)

The Apple TV screensaver for your mac, now with optional wallpaper continuity. With optional overlays, multi-monitor support, time-of-day adaptation, live camera feeds support and many more features. 

Check-out the website for more info : [aerialscreensaver.github.io](https://aerialscreensaver.github.io)

## Requirements

- macOS 26 (Tahoe) or later.
- Xcode 16 or later to build from source.

For earlier macOS versions, check the [download page](https://aerialscreensaver.github.io/download/) to see the last supported release.

## Something not working ? 

Bugs happen, and some features may not work as intended. 

First, make sure you check out the [FAQ](https://aerialscreensaver.github.io/faq/) as it contains a lot of information about limitations and how to use some of the more niche features. 

If you don't find your answer, you can check the existing [issues](https://github.com/AerialScreensaver/Aerial/issues) and post your own if nothing match. Or you can reach out on our [Discord server](https://discord.com/invite/TPuA5WG) in the `#support` channel. 

Whichever way you pick, remember Aerial is very much a one-person passion project. Be kind.

Interested in how it works? See the technical info below.

## App Extension

With version 4.0, the screensaver is distributed as an App Extension, bundled inside `Aerial.app`. Launching the app  registers the screensaver which can then be found in System Settings, ready to be used. 

Screensaver App Extensions were introduced by Apple in macOS 10.*15* (yes, Catalina!) and bring a lot of improvements, including a much improved security model compared to the old, unsafe, plugins that shared their host's memory. Screensaver App Extensions run in their own sandboxed process instead. They also fix many issues that have crept in over the years with the old `.saver` plugin format and its `legacyScreenSaver.appex` compatibility layer.

If you want to make your own macOS screensaver App Extension, I recommend you check [AppexSaverMinimal](https://github.com/AerialScreensaver/AppexSaverMinimal) first. It's a minimal working sample, with a clear documentation of what works, what changed from the old API, and what you should adapt if you already have a `.saver` project. Porting an existing `.saver` project is fairly easy as much of the old API is retained, with a few caveats. 

Version 4.1 of Aerial went one step further and moved to the `com.apple.wallpaper` extension point, backed by Apple's private `WallpaperExtensionKit` framework. Those extensions register as both a dynamic wallpaper and a screensaver. This is what enables the seamless continuity that Aerial 4 provides. It is however a more complex and undocumented API, with a very different instance-based lifecycle and remote `CAContext` rendering.  

To enable wallpapers and screensavers, Aerial relies on [PaperSaver](https://github.com/AerialScreensaver/PaperSaver). You can use this library to set your own screensaver as the old `defaults` plist configuration no longer works.

## Build from source

```bash
git clone https://github.com/AerialScreensaver/Aerial.git
cd Aerial
open Aerial.xcodeproj
```

In Xcode, pick the **Aerial** scheme and run (`⌘R`).

Note that `ScreenSaver/Source/Models/API/APISecrets.swift` ships with a blank OpenWeather key in the public source. The weather overlay won't display data unless you put your own key. Everything else in the app works without it.

## Thank you

Weather overlays are provided thanks to [Openweather](https://openweathermap.org) who has offerred free support for Aerial for *many* years now ! Many thanks to them !

<a href="https://openweathermap.org"><img src="Aerial/Resources/Assets.xcassets/OpenWeatherLogo.imageset/ow_logo.svg" alt="OpenWeather" width="200"></a>

Aerial relies on a few great open source projects, you should check them out : 
- [Sparkle](https://sparkle-project.org) for auto-updates
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus for global shortcuts handling
- [Github releases to discord](https://github.com/SethCohen/github-releases-to-discord) by Seth Cohen for release notes in the community Discord
- [Swift Argument parser](https://github.com/apple/swift-argument-parser) by Apple (not used directly by Aerial, but [PaperSaver](https://github.com/AerialScreensaver/PaperSaver) does use it)
- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) by Jonas van den Berg which restored access to the `mediaremote` framework
- [PaperSaver](https://github.com/AerialScreensaver/PaperSaver) by Guillaume Louel to enable the app extensions

Thanks to those maintainers and their contributors !

And finally, to everyone who has used, supported or contributed to Aerial, thanks for your continued support over those long years! 

## Contributing

Contributions welcome, but **please open an issue first** for substantial changes so we can discuss the approach before you put time into it.

## License

MIT — see [LICENSE](LICENSE).
