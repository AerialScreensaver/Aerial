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
    /// Aerial 3 data the wizard found but could not read (Full Disk
    /// Access), skipped by the user — gated on `legacyMigrationPending`
    /// and on the data being readable now. Cleared by a completed
    /// migration. Runs the same operations as the wizard's step.
    case legacyMigration

    /// Pages still owed by this install. Empty for new installs (the
    /// wizard sets both sentinels) and for anyone who has answered.
    static func pending() -> [UpgradePromptPage] {
        var pages: [UpgradePromptPage] = []
        if !Preferences.wallpaperModeChosen { pages.append(.wallpaperMode) }
        if !Preferences.appPresentationChosen { pages.append(.presentation) }
        if Preferences.legacyMigrationPending {
            PathMigration.probeLegacyData()
            if PathMigration.legacyDataFound, PathMigration.legacyDataReadable {
                pages.append(.legacyMigration)
            }
        }
        if LegacyExternalCacheMigration.pendingFolder != nil { pages.append(.externalCache) }
        return pages
    }
}

/// What to do with Aerial 3 data once it can be read (the re-offer page).
enum LegacyMigrationChoice: CaseIterable {
    case migrate, keepCustom, startFresh

    /// Keep custom only makes sense for a 3.x custom cache location.
    static func cases(customCache: Bool) -> [LegacyMigrationChoice] {
        customCache ? [.migrate, .keepCustom, .startFresh] : [.migrate, .startFresh]
    }

    var symbol: String {
        switch self {
        case .migrate: return "arrow.down.doc.fill"
        case .keepCustom: return "externaldrive"
        case .startFresh: return "sparkles"
        }
    }

    var title: String {
        switch self {
        case .migrate: return "Migrate"
        case .keepCustom: return "Keep custom location"
        case .startFresh: return "Start fresh"
        }
    }

    var tagline: String {
        switch self {
        case .migrate: return "Recommended — carry over videos, sources and settings"
        case .keepCustom: return "Keep playing from the Aerial 3 cache folder"
        case .startFresh: return "Nothing is carried over"
        }
    }

    var actionButtonTitle: String {
        switch self {
        case .migrate: return "Migrate Now"
        case .keepCustom: return "Keep"
        case .startFresh: return "Start Fresh"
        }
    }

    var migrationType: MigrationType {
        switch self {
        case .migrate: return .moveData
        case .keepCustom: return .keepCustom
        case .startFresh: return .startFresh
        }
    }

    func bullets(customCacheFolder: String?) -> [String] {
        switch self {
        case .migrate:
            var lines = ["Move your downloaded videos and any custom source packs to Aerial 4",
                         "Carry over some key basic settings"]
            if let folder = customCacheFolder {
                lines.insert("Move the videos in `\(folder)` to `\(Cache.defaultCachePath)`", at: 0)
            }
            lines.append("The old data is moved (not copied) — disk space is freed automatically")
            return lines
        case .keepCustom:
            return ["Aerial keeps playing from `\(customCacheFolder ?? "the Aerial 3 cache folder")`",
                    "If the wallpaper extension can't read that folder, Aerial offers to move or convert it next",
                    "Everything else stays where it is"]
        case .startFresh:
            return ["Start Aerial 4 with default settings — nothing is carried over",
                    "Leave the old data untouched (you can remove it manually later)"]
        }
    }
}

/// Cards + bullet pane + progress / error rows for the re-offer page.
struct LegacyMigrationChooser: View {
    let customCacheFolder: String?
    @Binding var selection: LegacyMigrationChoice
    let progress: String?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(LegacyMigrationChoice.cases(customCache: customCacheFolder != nil), id: \.self) { choice in
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

            FirstLaunchBulletPane(lines: selection.bullets(customCacheFolder: customCacheFolder))

            if let progress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress)
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

/// What to do with a plain cache folder the extension cannot read.
enum LegacyCacheChoice: CaseIterable {
    case convert, moveToDefault, useInternal, later

    /// The cards for a folder, recommended one first. A folder on the boot
    /// volume can simply move to the default location (a rename on the
    /// same disk), so that is the offer there and "use internal, leave the
    /// videos" makes no sense; a /Volumes folder keeps the 4.0 → 4.1 set,
    /// where the image is the way to stay on the drive.
    static func cases(for folder: String) -> [LegacyCacheChoice] {
        LegacyExternalCacheMigration.isOnExternalVolume(folder)
            ? [.convert, .useInternal, .later]
            : [.moveToDefault, .convert, .later]
    }

    static func recommended(for folder: String) -> LegacyCacheChoice {
        cases(for: folder).first ?? .convert
    }

    var symbol: String {
        switch self {
        case .convert: return "externaldrive.badge.checkmark"
        case .moveToDefault: return "internaldrive.fill"
        case .useInternal: return "internaldrive"
        case .later: return "clock"
        }
    }

    var title: String {
        switch self {
        case .convert: return "Move into a disk image"
        case .moveToDefault: return "Move to the default location"
        case .useInternal: return "Use the internal cache"
        case .later: return "Decide later"
        }
    }

    func tagline(folder: String) -> String {
        switch self {
        case .convert:
            return LegacyExternalCacheMigration.isOnExternalVolume(folder)
                ? "Recommended — the videos stay on this drive"
                : "The videos stay in this folder, inside a disk image"
        case .moveToDefault: return "Recommended — a quick move on the same disk"
        case .useInternal: return "The videos stay in the folder, unused"
        case .later: return "Ask again next time Aerial starts"
        }
    }

    /// The page's button for the choices that run an action before the
    /// page can be left; nil for the ones that just commit on Next.
    var actionButtonTitle: String? {
        switch self {
        case .convert: return "Convert Now"
        case .moveToDefault: return "Move Now"
        case .useInternal, .later: return nil
        }
    }

    func bullets(folder: String, inventory: LegacyExternalCacheMigration.Inventory) -> [String] {
        let videos = "\(inventory.count) video\(inventory.count == 1 ? "" : "s") (\(inventory.formattedBytes))"
        switch self {
        case .convert:
            return ["Create **\(ExternalCacheImage.bundleName)** inside `\(folder)`",
                    "Move the \(videos) into it — nothing is deleted",
                    "The wallpaper extension plays from the image, attached by Aerial when it starts"]
        case .moveToDefault:
            return ["Move the \(videos) to `\(Cache.defaultCachePath)` — a rename on the same disk, nothing is deleted",
                    "Move any Expansion packs in `\(folder)/Expansions` back to `\(Cache.defaultSourcesRoot)`",
                    "Switch off the custom cache location — the wallpaper extension plays from the default cache right away"]
        case .useInternal:
            return ["Switch the cache back to `\(Cache.defaultCachePath)`",
                    "Leave the \(videos) in the folder — Settings › Cache can still convert it later",
                    "Videos are downloaded again to the internal disk as needed"]
        case .later:
            return ["Keep the current setting for now",
                    "Nothing plays on the desktop until the videos are moved or the folder is converted",
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
                ForEach(LegacyCacheChoice.cases(for: folder), id: \.self) { choice in
                    FirstLaunchCard(
                        symbol: choice.symbol,
                        title: choice.title,
                        tagline: choice.tagline(folder: folder),
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
                            Text("Moving videos and packs… \(done)/\(total)")
                        } else {
                            ProgressView().controlSize(.small)
                            Text("Moving videos and packs…")
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
    /// Mutable: a migration that imports a 3.x custom cache can add the
    /// external-cache page behind it.
    @State private var pages: [UpgradePromptPage]
    let onComplete: () -> Void

    init(pages: [UpgradePromptPage], onComplete: @escaping () -> Void) {
        _pages = State(initialValue: pages)
        self.onComplete = onComplete
    }

    @State private var pageIndex = 0
    @State private var wallpaperMode: WallpaperMode = FirstLaunch.initialWallpaperMode
    @State private var presentation: AppPresentation = FirstLaunch.initialPresentation

    // External-cache page state. The folder and inventory are captured
    // once: the conversion changes the prefs underneath the page.
    @State private var cacheChoice: LegacyCacheChoice = LegacyCacheChoice.recommended(
        for: LegacyExternalCacheMigration.pendingFolder ?? "")
    @State private var legacyFolder: String = LegacyExternalCacheMigration.pendingFolder ?? ""
    @State private var legacyInventory = LegacyExternalCacheMigration.inventory(
        folder: LegacyExternalCacheMigration.pendingFolder ?? "")
    @State private var conversionStep: LegacyExternalCacheMigration.Step?
    @State private var conversionError: String?
    @State private var isConverting = false
    /// Pages whose action already ran (their button then reads Next).
    @State private var actionDone: Set<UpgradePromptPage> = []

    // Legacy-migration page state.
    @State private var migrationChoice: LegacyMigrationChoice = .migrate
    @State private var migrationProgress: String?

    private var isLastPage: Bool { pageIndex >= pages.count - 1 }

    /// The action pages (external cache, legacy migration) run their
    /// operation on their own button press before they can be left; every
    /// other page just commits and advances.
    private var currentAction: String? {
        switch pages[pageIndex] {
        case .externalCache: return cacheChoice.actionButtonTitle
        case .legacyMigration: return migrationChoice.actionButtonTitle
        case .wallpaperMode, .presentation: return nil
        }
    }

    private var needsActionFirst: Bool {
        currentAction != nil && !actionDone.contains(pages[pageIndex])
    }

    private var buttonTitle: String {
        if needsActionFirst, let action = currentAction {
            return conversionError == nil ? action : "Retry"
        }
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
            case .legacyMigration:
                header(
                    "Aerial 3 data can now be migrated",
                    "Aerial can now read the data from your previous Aerial install. Choose what to do with it — the same choices the setup assistant offered."
                )
                LegacyMigrationChooser(
                    customCacheFolder: PathMigration.getCustomCachePath(),
                    selection: $migrationChoice,
                    progress: migrationProgress,
                    error: conversionError
                )
            case .externalCache:
                if LegacyExternalCacheMigration.isOnExternalVolume(legacyFolder) {
                    header(
                        "Your video cache is on an external drive",
                        "Aerial 4.1 plays videos from a macOS extension that can only reach an external drive through a disk image. Aerial can create one inside your existing cache folder and move your videos and Expansion packs into it. Your current cache: \(legacyFolder)"
                    )
                } else {
                    header(
                        "Your video cache is in a folder Aerial can't read",
                        "Aerial 4.1 plays videos from a macOS extension that can only access /Users/Shared. Aerial can move your videos and Expansion packs to the default cache on this disk, or keep them in this folder inside a disk image. It's highly recommended you let Aerial move your videos to the new folder. Your current cache: \(legacyFolder)"
                    )
                }
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
        if needsActionFirst {
            startAction()
            return
        }
        commitCurrentPage()
        if isLastPage {
            onComplete()
        } else {
            pageIndex += 1
        }
    }

    private func startAction() {
        switch pages[pageIndex] {
        case .legacyMigration:
            startLegacyMigration()
        case .externalCache:
            startCacheAction()
        case .wallpaperMode, .presentation:
            break
        }
    }

    /// The re-offer page: the wizard's operations, then — when a 3.x
    /// custom cache was imported and the extension cannot read it — the
    /// external-cache page is queued behind this one.
    private func startLegacyMigration() {
        isConverting = true
        conversionError = nil
        migrationProgress = "Preparing…"
        PathMigration.performMigration(
            type: migrationChoice.migrationType,
            progressCallback: { message in
                DispatchQueue.main.async { migrationProgress = message }
            },
            completion: { result in
                DispatchQueue.main.async {
                    migrationProgress = nil
                    isConverting = false
                    switch result {
                    case .success, .skipped:
                        actionDone.insert(.legacyMigration)
                        if let folder = LegacyExternalCacheMigration.pendingFolder, !pages.contains(.externalCache) {
                            pages.append(.externalCache)
                            legacyFolder = folder
                            legacyInventory = LegacyExternalCacheMigration.inventory(folder: folder)
                            cacheChoice = LegacyCacheChoice.recommended(for: folder)
                        }
                        advance()
                    case .failure(let error, _):
                        conversionError = error
                    }
                }
            }
        )
    }

    private func startCacheAction() {
        isConverting = true
        conversionError = nil
        let folder = legacyFolder
        switch cacheChoice {
        case .convert:
            conversionStep = .creatingImage
            Task { @MainActor in
                do {
                    let outcome = try await LegacyExternalCacheMigration.convert(folder: folder) { step in
                        conversionStep = step
                    }
                    finishAction(failed: outcome.failed,
                                 failureText: "\(outcome.failed) video(s) or pack(s) could not be moved into the disk image and stay in the folder. See Settings › Cache.")
                } catch {
                    errorLog("💽 legacy external cache conversion failed for \(folder): \(error.localizedDescription)")
                    conversionStep = nil
                    isConverting = false
                    conversionError = error.localizedDescription
                }
            }
        case .moveToDefault:
            // Starts at "moving" — there is no image step to show.
            conversionStep = .moving(done: 0, total: 0)
            Task { @MainActor in
                let outcome = await LegacyExternalCacheMigration.moveToDefaultLocation(folder: folder) { step in
                    conversionStep = step
                }
                finishAction(failed: outcome.failed,
                             failureText: "\(outcome.failed) video(s) or pack(s) could not be moved to the default cache and stay in \(folder) — see the log.")
            }
        case .useInternal, .later:
            isConverting = false
        }
    }

    /// Done, possibly with leftovers: say so and let the user continue —
    /// the folder is no longer a legacy one either way, so the page won't
    /// come back.
    private func finishAction(failed: Int, failureText: String) {
        conversionStep = nil
        isConverting = false
        actionDone.insert(pages[pageIndex])
        if failed > 0 {
            conversionError = failureText
        } else {
            advance()
        }
    }

    private func commitCurrentPage() {
        switch pages[pageIndex] {
        case .wallpaperMode:
            FirstLaunch.apply(wallpaperMode: wallpaperMode)
        case .presentation:
            FirstLaunch.apply(presentation: presentation)
        case .legacyMigration:
            break   // already done in startAction
        case .externalCache:
            switch cacheChoice {
            case .convert, .moveToDefault:
                break   // already done in startAction
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
