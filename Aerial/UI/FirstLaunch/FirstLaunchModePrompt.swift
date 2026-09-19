//
//  FirstLaunchModePrompt.swift
//  Aerial Companion
//
//  The one-time upgrade prompt shown to *existing* users — those who
//  never went through the wizard steps that record a decision. Each
//  page is gated on its own sentinel (`wallpaperModeChosen`,
//  `appPresentationChosen`), so a user is asked exactly once per
//  decision, and every pending decision shares ONE window with a
//  page-of-N footer: no consecutive modals (the wizard's rule).
//
//  New installs choose the same things inside the full first-launch
//  wizard; both paths reuse the same choosers and commit through
//  `FirstLaunch.apply(...)`.
//
//  Deliberately lighter than the full wizard — no overlays, nothing the
//  user has already set up.
//

import Cocoa
import SwiftUI

// MARK: - Reusable three-card chooser

/// The three Sonoma+ wallpaper-mode cards (off / still / live) plus the
/// shared "This will:" bullet pane. Used by both the wizard's mode step
/// and the standalone upgrade prompt.
struct WallpaperModeChooser: View {
    @Binding var selection: WallpaperMode

    private let choices: [WallpaperMode] = [.off, .paused, .animated]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(choices, id: \.self) { choice in
                    FirstLaunchCard(
                        symbol: choice.thumbnailSymbol,
                        title: choice.title,
                        tagline: choice.tagline,
                        isSelected: selection == choice,
                        onSelect: { selection = choice }
                    )
                    .frame(maxWidth: .infinity)
                }
            }

            FirstLaunchBulletPane(lines: selection.settingsBullets)
        }
    }
}

// MARK: - Pages

/// The decisions the upgrade prompt can ask for, in display order.
enum UpgradePromptPage: CaseIterable {
    /// 4.1 three-mode wallpaper model — gated on `wallpaperModeChosen`.
    case wallpaperMode
    /// 4.1 menu bar vs Dock — gated on `appPresentationChosen`.
    case presentation
    /// A plain video cache folder outside /Users/Shared (a 4.0-style
    /// cache on an external drive, or a folder in the home) that the 4.1
    /// wallpaper extension cannot read. No sentinel: the page exists while
    /// the configuration does and the folder is reachable, and goes away
    /// once the user converts the folder or switches to the internal
    /// cache. "Decide later" brings it back at the next launch.
    case externalCache

    /// Pages still owed by this install. Empty for new installs (the
    /// wizard sets both sentinels) and for anyone who has answered.
    static func pending() -> [UpgradePromptPage] {
        var pages: [UpgradePromptPage] = []
        if !Preferences.wallpaperModeChosen { pages.append(.wallpaperMode) }
        if !Preferences.appPresentationChosen { pages.append(.presentation) }
        if LegacyExternalCacheMigration.pendingFolder != nil { pages.append(.externalCache) }
        return pages
    }
}

/// What to do with a plain cache folder the extension cannot read.
enum LegacyCacheChoice: CaseIterable {
    case convert, useInternal, later

    var symbol: String {
        switch self {
        case .convert: return "externaldrive.badge.checkmark"
        case .useInternal: return "internaldrive"
        case .later: return "clock"
        }
    }

    var title: String {
        switch self {
        case .convert: return "Move into a disk image"
        case .useInternal: return "Use the internal cache"
        case .later: return "Decide later"
        }
    }

    var tagline: String {
        switch self {
        case .convert: return "Recommended — the videos stay in this folder"
        case .useInternal: return "The videos stay in the folder, unused"
        case .later: return "Ask again next time Aerial starts"
        }
    }

    func bullets(folder: String, inventory: LegacyExternalCacheMigration.Inventory) -> [String] {
        let videos = "\(inventory.count) video\(inventory.count == 1 ? "" : "s") (\(inventory.formattedBytes))"
        switch self {
        case .convert:
            return ["Create **\(ExternalCacheImage.bundleName)** inside `\(folder)`",
                    "Move the \(videos) into it — nothing is deleted",
                    "The wallpaper extension plays from the image, attached by Aerial when it starts"]
        case .useInternal:
            return ["Switch the cache back to `/Users/Shared/Aerial/Cache`",
                    "Leave the \(videos) in the folder — Settings › Cache can still convert it later",
                    "Videos are downloaded again to the internal disk as needed"]
        case .later:
            return ["Keep the current setting for now",
                    "Nothing plays on the desktop until the folder is converted",
                    "This page comes back the next time Aerial starts"]
        }
    }
}

/// Three cards + the bullet pane + progress / error rows for the
/// external-cache page.
struct LegacyExternalCacheChooser: View {
    let folder: String
    let inventory: LegacyExternalCacheMigration.Inventory
    @Binding var selection: LegacyCacheChoice
    let step: LegacyExternalCacheMigration.Step?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(LegacyCacheChoice.allCases, id: \.self) { choice in
                    FirstLaunchCard(
                        symbol: choice.symbol,
                        title: choice.title,
                        tagline: choice.tagline,
                        isSelected: selection == choice,
                        onSelect: { selection = choice }
                    )
                    .frame(maxWidth: .infinity)
                }
            }

            FirstLaunchBulletPane(lines: selection.bullets(folder: folder, inventory: inventory))

            if let step {
                HStack(spacing: 8) {
                    switch step {
                    case .creatingImage:
                        ProgressView().controlSize(.small)
                        Text("Creating the disk image…")
                    case .attaching:
                        ProgressView().controlSize(.small)
                        Text("Attaching…")
                    case .moving(let done, let total):
                        if total > 0 {
                            ProgressView(value: Double(done), total: Double(total))
                                .frame(maxWidth: 240)
                            Text("Moving videos… \(done)/\(total)")
                        } else {
                            ProgressView().controlSize(.small)
                            Text("Moving videos…")
                        }
                    }
                }
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Standalone prompt view

struct UpgradePromptView: View {
    let pages: [UpgradePromptPage]
    let onComplete: () -> Void

    @State private var pageIndex = 0
    @State private var wallpaperMode: WallpaperMode = FirstLaunch.initialWallpaperMode
    @State private var presentation: AppPresentation = FirstLaunch.initialPresentation

    // External-cache page state. The folder and inventory are captured
    // once: the conversion changes the prefs underneath the page.
    @State private var cacheChoice: LegacyCacheChoice = .convert
    @State private var legacyFolder: String = LegacyExternalCacheMigration.pendingFolder ?? ""
    @State private var legacyInventory = LegacyExternalCacheMigration.inventory(
        folder: LegacyExternalCacheMigration.pendingFolder ?? "")
    @State private var conversionStep: LegacyExternalCacheMigration.Step?
    @State private var conversionError: String?
    @State private var isConverting = false
    @State private var conversionDone = false

    private var isLastPage: Bool { pageIndex >= pages.count - 1 }

    /// The external-cache page runs the conversion on its own button press
    /// before it can be left; every other page just commits and advances.
    private var needsConversionFirst: Bool {
        pages[pageIndex] == .externalCache && cacheChoice == .convert && !conversionDone
    }

    private var buttonTitle: String {
        if needsConversionFirst { return conversionError == nil ? "Convert Now" : "Retry" }
        return isLastPage ? "Continue" : "Next"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch pages[pageIndex] {
            case .wallpaperMode:
                header(
                    "Aerial 4 wallpaper",
                    "Aerial now powers your wallpaper through a macOS wallpaper extension. Choose how you'd like it to behave — you can change this any time from Aerial or Settings."
                )
                WallpaperModeChooser(selection: $wallpaperMode)
            case .presentation:
                header(
                    "Where should Aerial live?",
                    "Aerial can stay in your menu bar as a compact popover, or run as a regular app in the Dock with the Video Library as its main window. You can switch any time in Settings → Advanced."
                )
                AppPresentationChooser(selection: $presentation)
            case .externalCache:
                header(
                    "Your video cache needs a disk image",
                    "Aerial 4.1 plays videos from a macOS extension that can only reach a cache outside /Users/Shared (an external drive or your home folder) through a disk image. Aerial can create one inside your existing cache folder and move your videos and Expansion packs into it. Your current cache: \(legacyFolder)"
                )
                LegacyExternalCacheChooser(
                    folder: legacyFolder,
                    inventory: legacyInventory,
                    selection: $cacheChoice,
                    step: conversionStep,
                    error: conversionError
                )
            }

            Spacer(minLength: 0)

            HStack {
                if pages.count > 1 {
                    Text("\(pageIndex + 1) of \(pages.count)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(buttonTitle) {
                    advance()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isConverting)
            }
        }
        .padding(24)
        .frame(width: 720, height: 540)
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func advance() {
        if needsConversionFirst {
            startConversion()
            return
        }
        commitCurrentPage()
        if isLastPage {
            onComplete()
        } else {
            pageIndex += 1
        }
    }

    private func startConversion() {
        isConverting = true
        conversionError = nil
        conversionStep = .creatingImage
        let folder = legacyFolder
        Task { @MainActor in
            do {
                let outcome = try await LegacyExternalCacheMigration.convert(folder: folder) { step in
                    conversionStep = step
                }
                conversionStep = nil
                isConverting = false
                conversionDone = true
                if outcome.failed > 0 {
                    // Converted, but some files stayed behind: say so and
                    // let the user continue — the folder is no longer a
                    // legacy one, so the page won't come back.
                    conversionError = "\(outcome.failed) video(s) or pack(s) could not be moved into the disk image and stay in the folder. See Settings › Cache."
                } else {
                    advance()
                }
            } catch {
                errorLog("💽 legacy external cache conversion failed for \(folder): \(error.localizedDescription)")
                conversionStep = nil
                isConverting = false
                conversionError = error.localizedDescription
            }
        }
    }

    private func commitCurrentPage() {
        switch pages[pageIndex] {
        case .wallpaperMode:
            FirstLaunch.apply(wallpaperMode: wallpaperMode)
        case .presentation:
            FirstLaunch.apply(presentation: presentation)
        case .externalCache:
            switch cacheChoice {
            case .convert:
                break   // already done in startConversion
            case .useInternal:
                LegacyExternalCacheMigration.useInternalCache()
            case .later:
                LegacyExternalCacheMigration.deferredThisSession = true
                debugLog("💽 legacy external cache: user deferred the conversion")
            }
        }
    }
}

// MARK: - Window controller

/// Modal host for the upgrade prompt. Mirrors
/// `FirstLaunchWizardWindowController` — titled, centered, not closable
/// (every page has a default selection, then Next / Continue).
class UpgradePromptWindowController: NSWindowController {

    private let pages: [UpgradePromptPage]
    private var onComplete: (() -> Void)?

    init(pages: [UpgradePromptPage]) {
        self.pages = pages
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Aerial 4.1"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func windowDidLoad() {
        super.windowDidLoad()

        let view = UpgradePromptView(pages: pages) { [weak self] in
            self?.close()
            self?.onComplete?()
        }

        window?.contentViewController = NSHostingController(rootView: view)
    }

    /// Show modally and call `onComplete` after the last page's Continue.
    func showModal(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: window!)
    }

    override func close() {
        NSApp.stopModal()
        super.close()
    }
}
