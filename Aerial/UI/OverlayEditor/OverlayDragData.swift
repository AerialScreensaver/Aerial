//
//  OverlayDragData.swift
//  Aerial
//
//  Codable, Transferable struct for drag & drop in the overlay editor.
//

import Foundation
import UniformTypeIdentifiers
import CoreTransferable

/// UTType for overlay drag data
extension UTType {
    static let overlayDrag = UTType(exportedAs: "com.glouel.aerial.overlay-drag")
}

/// Data transferred during drag & drop of overlay types
struct OverlayDragData: Codable, Transferable, Equatable {
    var kind: OverlayKind
    var existingInstanceID: UUID?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(for: OverlayDragData.self, contentType: .overlayDrag)
    }
}
