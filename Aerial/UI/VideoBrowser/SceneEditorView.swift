//
//  SceneEditorView.swift
//  Aerial Companion
//
//  Editable scene picker for "My Videos" entries. Unlike the time-of-day
//  override, this writes the chosen scene directly into the video's
//  entries.json — My Videos has no upstream manifest to override against,
//  so the manifest value is the source of truth.
//

import SwiftUI

struct SceneEditorView: View {
    let video: AerialVideo
    @ObservedObject var state: VideoBrowserState

    /// Buttons per row → a 3×2 grid over the six `SourceScene` cases.
    private let columns = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scene")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            VStack(spacing: 2) {
                ForEach(sceneRows, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(row, id: \.self) { scene in
                            sceneButton(scene)
                        }
                    }
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
    }

    /// Chunk the six scenes into rows of `columns` for the grid.
    private var sceneRows: [[SourceScene]] {
        let all = SourceScene.allCases
        return stride(from: 0, to: all.count, by: columns).map {
            Array(all[$0 ..< min($0 + columns, all.count)])
        }
    }

    private func sceneButton(_ scene: SourceScene) -> some View {
        let isActive = video.scene == scene
        return Button(action: { applyScene(scene) }) {
            VStack(spacing: 2) {
                Image(systemName: sceneIcon(scene))
                    .font(.system(size: 14))
                Text(scene.rawValue)
                    .font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isActive ? Color.aerial.opacity(0.15) : Color.clear)
            .foregroundColor(isActive ? .aerial : .secondary)
            .cornerRadius(4)
        }
        .buttonStyle(.borderless)
        .help("Set scene to \(scene.rawValue)")
        .accessibilityLabel("Set scene to \(scene.rawValue)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // MARK: - Actions

    private func applyScene(_ scene: SourceScene) {
        guard video.scene != scene else { return }

        // Mutate the shared model instance in place so the grid, sidebar
        // grouping and inspector all reflect the change on next refresh.
        video.scene = scene

        // Persist directly into My Videos' entries.json (this is a direct
        // edit, not an override).
        writeScene(scene.rawValue.lowercased())

        state.refreshTrigger += 1
    }

    /// Rewrites the matching asset's `scene` in entries.json, preserving
    /// every other field — notably `type`, which must stay untouched.
    /// Mirrors `updateMyVideoTitle` in `VideoInspectorView`.
    private func writeScene(_ sceneValue: String) {
        let entriesPath = Cache.supportPath.appending("/Sources/My Videos/entries.json")
        guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: entriesPath)),
              let manifest = try? newJSONDecoder().decode(VideoManifest.self, from: jsonData) else {
            return
        }

        let updatedAssets = manifest.assets.map { asset -> VideoAsset in
            guard asset.id == video.id else { return asset }
            return VideoAsset(
                accessibilityLabel: asset.accessibilityLabel,
                id: asset.id,
                title: asset.title,
                timeOfDay: asset.timeOfDay,
                scene: sceneValue,
                pointsOfInterest: asset.pointsOfInterest,
                url4KHDR: asset.url4KHDR,
                url4KSDR: asset.url4KSDR,
                url1080H264: asset.url1080H264,
                url1080HDR: asset.url1080HDR,
                url4KSDR120FPS: asset.url4KSDR120FPS,
                url4KSDR240FPS: asset.url4KSDR240FPS,
                url1080SDR: asset.url1080SDR,
                url: asset.url,
                type: asset.type
            )
        }

        let updatedManifest = VideoManifest(
            assets: updatedAssets,
            initialAssetCount: manifest.initialAssetCount,
            version: manifest.version
        )

        if let source = SourceList.list.first(where: { $0.name == "My Videos" && $0.type == .local }) {
            SourceList.saveEntries(source: source, manifest: updatedManifest)
        }
    }
}

struct SceneEditorView_Previews: PreviewProvider {
    static var previews: some View {
        let video = PreviewData.makeVideo()
        SceneEditorView(video: video, state: PreviewData.makeState())
            .padding(12)
            .frame(width: 260)
    }
}
