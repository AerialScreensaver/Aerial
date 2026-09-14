// Protocol conformance the agent requires but Aerial doesn't use:
// settings/choices plumbing answered with live view models where needed
// and no-op replies everywhere else (downloads, migration, shuffle —
// Aerial manages its own content). Split out of WallpaperXPCHandler.swift
// (2026-07-07); `handleDebugRequest`/`handleNotification` stay with the
// main class (they carry real behavior — wake recovery).

import Foundation

extension WallpaperXPCHandler {
    // MARK: - Settings

    func provideSettingsViewModels(withContentTypes _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        debugLog("=== PROVIDE SETTINGS VIEW MODELS ===")
        Task {
            if let result = await buildSettingsViewModelsXPC() {
                reply(result, nil)
            } else {
                reply(makeEmptyGroupsResponse(), nil)
            }
        }
    }

    // MARK: - Choices

    func addChoiceRequest(withChoiceRequest req: Any?, onBehalfOfProcess _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        debugLog("=== ADD CHOICE REQUEST ===")
        if let obj = req as? NSObject { dumpMirror(obj, label: "addChoice.req", depth: 4) }
        reply(nil, nil)
    }

    func removeChoiceRequest(withChoiceRequest req: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        debugLog("=== REMOVE CHOICE REQUEST ===")
        if let obj = req as? NSObject { dumpMirror(obj, label: "removeChoice.req", depth: 4) }
        reply(nil)
    }

    func selectedChoicesDidChange(for id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        debugLog("=== SELECTED CHOICES DID CHANGE ===")
        if let obj = id as? NSObject { dumpMirror(obj, label: "selectedChoices.id", depth: 4) }
        reply(nil)
    }

    func invokeContextMenuAction(withMenuItemID _: Any?, groupItemID _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    // MARK: - Downloads (stubs)

    func isChoiceDownloaded(with _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        reply(true, nil)
    }

    func download(withChoiceID _: Any?, reply: ((any Error)?) -> Void) -> Any? {
        reply(nil)
        return nil
    }

    func pauseDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func cancelDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func resumeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func removeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    // MARK: - Migration (stubs)

    func migrateSelectedChoice(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        reply(nil, nil)
    }

    func migrate(from _: Any?, to _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    // MARK: - Shuffle (stubs)

    func skipShuffledContent(withId _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func canSkipShuffledContent(withId _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        reply(false, nil)
    }
}
