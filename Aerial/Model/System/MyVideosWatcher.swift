//
//  MyVideosWatcher.swift
//  Aerial
//
//  App-lifetime watcher on the My Videos folder so a file dropped in
//  Finder shows up in the library (and on the wallpaper) without the
//  user clicking Refresh. DispatchSource .write on the folder FD —
//  Finder drops land as direct children, which is exactly what that
//  event mask catches. Debounced: a copy-in-progress fires multiple
//  events (and our own panel imports fire it too); one trailing-edge
//  refresh covers them all.
//

import Foundation

final class MyVideosWatcher {
    static let shared = MyVideosWatcher()

    /// Posted (main thread) after the library refresh completes — the
    /// My Videos panel rescans its rows on this.
    static let folderChangedNotification = Notification.Name("com.glouel.aerial.myVideosFolderChanged")

    private let monitor = DirectoryMonitor(bookmarkData: nil)
    private var debounce: DispatchWorkItem?
    private var started = false

    private init() {}

    /// Idempotent — called from AppDelegate after
    /// `SourceList.ensureDefaultLocalSource()` guarantees the folder.
    func startIfNeeded() {
        guard !started else { return }
        started = true

        monitor.onChange = { [weak self] _ in
            self?.scheduleRefresh()
        }
        do {
            try monitor.startMonitoring(path: AerialPaths.myVideosPath())
            debugLog("📁 MyVideosWatcher watching \(AerialPaths.myVideosPath())")
        } catch {
            errorLog("📁 MyVideosWatcher failed to start: \(error.localizedDescription)")
        }
    }

    private func scheduleRefresh() {
        // onChange arrives on the monitor's utility queue — coalesce on
        // main where the refresh work wants to live anyway.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            debounce?.cancel()
            let work = DispatchWorkItem {
                debugLog("📁 My Videos folder changed — refreshing library")
                // Idempotent: updates the existing "My Videos" source
                // (diff against the folder) and reloads VideoList.
                SourceList.ensureDefaultLocalSource()
                NotificationCenter.default.post(name: Self.folderChangedNotification, object: nil)
            }
            debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }
}
