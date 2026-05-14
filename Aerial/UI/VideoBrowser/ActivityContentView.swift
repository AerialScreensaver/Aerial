//
//  ActivityContentView.swift
//  Aerial Companion
//
//  Activity feed for the Video Library. Surfaces recently-downloaded
//  videos in three time buckets — Today / Last 7 days / Last 30 days
//  (plus an Earlier catch-all for completeness) — newest first within
//  each. We don't keep a separate download log: the source of truth is
//  the cache file's `creationDate`, which is set by FileManager when
//  DownloadCoordinator moves the .mov into place.
//

import SwiftUI

struct ActivityContentView: View {
    @ObservedObject var state: VideoBrowserState

    private struct ActivitySection: Identifiable {
        let id: String
        let title: String
        let entries: [Entry]
    }

    private struct Entry: Identifiable {
        var id: String { video.id }
        let video: AerialVideo
        let date: Date
    }

    /// Re-evaluated whenever the view re-renders. The expensive part is
    /// one `attributesOfItem` per cached video — small caches make this
    /// trivial; with hundreds of cached entries the cost is still
    /// dominated by view rendering, not stat calls. The view re-renders
    /// when `state.refreshTrigger` ticks (download completes, manifest
    /// refresh, etc.) which is exactly when the bucketing might change.
    private var sections: [ActivitySection] {
        // Touch refreshTrigger so SwiftUI re-evaluates this body when
        // a download lands or other state changes — file mtimes alone
        // aren't published, so we ride the existing refresh signal.
        _ = state.refreshTrigger

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOf7d = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        let startOf30d = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday

        var entries: [Entry] = []
        for video in VideoList.instance.videos where video.isAvailableOffline {
            // Live feeds are "available" by convention but have no cache
            // file; skip them so we don't spam stat-failed logs.
            if video.isLive { continue }
            guard let path = VideoCache.cachePath(forVideo: video) else { continue }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            // Prefer creationDate (download time). Fall back to
            // modificationDate for filesystems that don't track create
            // times distinct from modify (rare on APFS but defensive).
            let date = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
            guard let date = date else { continue }
            entries.append(Entry(video: video, date: date))
        }
        entries.sort { $0.date > $1.date }   // newest first globally

        var today: [Entry] = []
        var last7d: [Entry] = []
        var last30d: [Entry] = []
        var earlier: [Entry] = []
        for entry in entries {
            if entry.date >= startOfToday { today.append(entry) }
            else if entry.date >= startOf7d { last7d.append(entry) }
            else if entry.date >= startOf30d { last30d.append(entry) }
            else { earlier.append(entry) }
        }

        var result: [ActivitySection] = []
        if !today.isEmpty   { result.append(ActivitySection(id: "today",   title: "Today",        entries: today)) }
        if !last7d.isEmpty  { result.append(ActivitySection(id: "7d",      title: "Last 7 days",  entries: last7d)) }
        if !last30d.isEmpty { result.append(ActivitySection(id: "30d",     title: "Last 30 days", entries: last30d)) }
        if !earlier.isEmpty { result.append(ActivitySection(id: "earlier", title: "Earlier",      entries: earlier)) }
        return result
    }

    var body: some View {
        let sections = self.sections
        let totalCount = sections.reduce(0) { $0 + $1.entries.count }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ContentHeader(
                    icon: "clock.arrow.circlepath",
                    title: "Activity",
                    description: "Recently downloaded videos, newest first. Grouped by when they landed in your cache."
                ) {
                    EmptyView()
                }

                if totalCount == 0 {
                    emptyState
                } else {
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                }
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.4))
            Text("No downloads yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Text("Open any video and tap Download in the inspector to start building your cache. Recent downloads will show up here.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    @ViewBuilder
    private func sectionView(_ section: ActivitySection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(section.title)
                    .font(.system(size: 16, weight: .semibold))
                Text("\(section.entries.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 200), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(section.entries) { entry in
                    VideoBrowserCardView(
                        video: entry.video,
                        state: state,
                        isCurrent: false,
                        showTimeMatch: state.currentTimeRestriction.active,
                        isMyVideos: false,
                        onTitleChanged: nil
                    )
                }
            }
        }
    }
}
