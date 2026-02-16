# Aerial Companion

<img width="400" alt="About Aerial Companion" src="https://user-images.githubusercontent.com/18543749/101047674-0441a980-3550-11eb-93d2-816aea42e209.jpg"> <img width="300" alt="Aerial Companion in Action!" src="https://user-images.githubusercontent.com/18543749/90840214-65d66300-e327-11ea-937c-6885f1ff1b4c.png">

The official companion app for the [Aerial screen saver](https://github.com/JohnCoates/Aerial/) for macOS. It takes care of install, automatic updates and more.

This utility will install the Aerial screensaver and keep you up to date! 

## Installation

1. Download the [latest release](https://github.com/glouel/AerialUpdater/releases)
2. Unzip and copy `AerialUpdater.app` to `/Applications` 

<img width="300" alt="Drag and Drop" src="https://user-images.githubusercontent.com/18543749/90923714-24dc5e00-e3bc-11ea-9a24-a650f42ea734.gif">

3. Once copied, double click to launch `Aerial.app` in your Applications Folder 

4. Aerial will be installed if this is your first time, or prompt you to update to the latest version! 

## Uninstall

- To uninstall the Aerial Companion App simply delete `Aerial.app` from your Applications folder. 
- To uninstall the Aerial screen saver, please follow the directions [here](https://github.com/JohnCoates/Aerial/blob/master/Documentation/Installation.md#uninstallation)

## I thought Aerial had auto-updates with Sparkle? 

Aerial used to automatically update (since [version 1.5.0](https://github.com/JohnCoates/Aerial/blob/master/Documentation/ChangeLog.md#150---may-31-2019)) using  the [Sparkle framework](https://sparkle-project.org). 

With the introduction of macOS 10.15 (Catalina), things changed for screen savers and Aerial was no longer able to update itself because of the new security restrictions introduced with sandboxing. A temporary workaround was put in place in [version 1.8.0](https://github.com/JohnCoates/Aerial/blob/master/Documentation/ChangeLog.md#180---february-18-2020) where you could get notified of a new version but not automatically install.

<img width="400" alt="Sparkle" src="https://user-images.githubusercontent.com/37544189/88542800-4e050b00-d017-11ea-8a80-6c9e0ef7b93b.jpg"> 

While this worked *most of the time*, for some users, the update check caused the `ScreenSaverEngine` to lose the keyboard/mouse focus, and pressing a key would no longer let you exit the screen saver (pressing `cmd-alt-shift-esc` could be used as a workaround). This issue seem to trigger a lot more often in macOS 11 (Big Sur). Due to this, Sparkle was removed from Aerial starting in version 2.0.0 and native support was added using Aerial Companion. 

## How does it work? 

During your first launch you will be able to set up Aerial Companion to keep you up to date the way that *you* want. Choose whether it checks for an update hourly, daily, weekly, or only when you want to update manually. Run the companion app in the foreground from your menubar, or in the background without any effort from you. Stay up to date with either stable releases or beta updates. 

## I meant, how does it work technically?

In this repository, I store a [manifest file](https://github.com/glouel/AerialUpdater/blob/main/manifest.json) that contains the version number of the latest release, and also the sha256 of the releases. This is generated after Aerial gets notarized for distribution and before I upload a new version on Aerial's [releases page](https://github.com/JohnCoates/Aerial/releases). 

Periodically, Aerial Companion checks the manifest to see if a new version was released. When you decide to perform an update, the following happens 
- Aerial Companion uses the version number from the manifest to infer the download link from Aerial's repository (the download links are always of the same format, so version `1.9.2` will be available at `https://github.com/JohnCoates/Aerial/releases/download/v1.9.2/Aerial.saver.zip`)
- The zip file is downloaded to `~/Library/Application Support/AerialUpdater/`
- The sha256 of the file is computed, and compared to the one from the manifest
- The zip is unzipped in place, looking for `Aerial.saver`
- `Aerial.saver` is verified (using macOS codesigning) to be using the correct Bundle ID (com.JohnCoates.Aerial)
- `Aerial.saver` is verified (using macOS codesigning) to be signed/notarized with my Developer Apple ID. 

If and only if everything checks out, then `Aerial.saver` gets copied to `~/Library/Screen Savers/`. 

## Do I have to use this? Is there an alternative?

You don't, and sure! 

- As pointed out in Aerial's [installation instructions](https://github.com/JohnCoates/Aerial/blob/master/Documentation/Installation.md), you can also use `homebrew` to install and/or update Aerial automatically.
- You will always be able to manually download and install Aerial from its Github repository.

## I don't want yet ANOTHER icon on my status bar!

Do not fear! After installing Aerial Companion you can do the following:

If you want to **update in the background** and hide the status icon: 
1. Change your `Check Every` settings to Hourly, Daily, or Weekly
2. Set your `Update Mode` to `Automatic`
3. Open the menu one last time and select `Launch > In the background (no menu)` 
4. This will then quit Aerial Companion and you are all set!

If you want to **update manually**
1. Simply quit Aerial Companion by clicking `Quit` at the bottom of the menu 
2. When you want to check for an update, launch `Aerial.app` from your `/Applications` folder and click `Check Now` from the menubar icon. 
3. Once installed, quit Aerial Companion again by clicking `Quit` at the bottom of the menu

## Known Issues

- This tool only installs/updates Aerial if you install it for your user only, and not for all users. Installing a screen saver for all users requires an administrator password at install, and at each subsequent update, defeating the purpose of an auto-updater. It's recommended to check if you have an `Aerial.saver` file in `/Library/Screen Savers/`. If you do, please remove it as you'll get two versions of Aerial alongside each other.  
- When updating a screen saver, you must first close System Preferences. If you don't, you will need to quit and restart System Preferences after installing to reload the new version as the old one will remain in memory. 

## Why should I trust you? Who are you?

I'm [Guillaume Louel](https://github.com/glouel), the developer of [Aerial](https://github.com/JohnCoates/Aerial/) since version 1.4. 

## I have more questions!

Great! We love questions! Please feel free to send us bug reports, feature requests, and ask questions through any of the following methods: 

- **Report bugs or post feature requests on [GitHub](https://github.com/glouel/AerialCompanion/issues)** 
- **Join our [Community Discord server](https://discord.gg/TPuA5WG)** for technical support, feature requests, and a fun time!
