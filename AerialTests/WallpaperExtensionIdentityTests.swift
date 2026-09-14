//
//  WallpaperExtensionIdentityTests.swift
//  AerialTests
//
//  Pins the stale-extension check's building blocks: identity matching
//  (version / build / executable mtime with tolerance, unknown never
//  matches), tolerant status decoding for the identity fields, and the
//  hosted-path classification used to spot the agent hosting another
//  copy of Aerial.
//

import Testing
import Foundation
@testable import Aerial

@Suite("Wallpaper Extension Identity")
struct WallpaperExtensionIdentityTests {

    private func identity(_ version: String = "4.1.0beta16",
                          build: String = "260901.1831",
                          mtime: Double = 1_000_000) -> WallpaperExtensionIdentity {
        WallpaperExtensionIdentity(version: version, build: build, binaryModified: mtime)
    }

    @Test func equalIdentitiesMatch() {
        #expect(identity().matches(identity()))
    }

    @Test func versionDifferenceBreaksMatch() {
        #expect(!identity().matches(identity("4.1.0beta17")))
    }

    @Test func buildDifferenceBreaksMatch() {
        #expect(!identity().matches(identity(build: "260902.0900")))
    }

    @Test func binaryTimeWithinToleranceMatches() {
        #expect(identity().matches(identity(mtime: 1_000_001.5)))
        #expect(identity(mtime: 1_000_001.5).matches(identity()))
    }

    @Test func binaryTimeBeyondToleranceBreaksMatch() {
        #expect(!identity().matches(identity(mtime: 1_000_010)))
    }

    @Test func unknownNeverMatches() {
        let unknown = WallpaperExtensionIdentity()
        #expect(!unknown.isKnown)
        #expect(!unknown.matches(identity()))
        #expect(!identity().matches(unknown))
        #expect(!unknown.matches(unknown))
        #expect(unknown.description == "unknown")
    }

    @Test func descriptionCarriesVersionAndBuild() {
        let desc = identity().description
        #expect(desc.contains("4.1.0beta16"))
        #expect(desc.contains("260901.1831"))
    }

    @Test func statusWithoutIdentityFieldsDecodesAsUnknown() throws {
        let json = """
        {"pid": 913, "lastSeen": 810038952.3, "appliedControlVersion": 8749}
        """
        let status = try JSONDecoder().decode(WallpaperStatusState.self, from: Data(json.utf8))
        #expect(status.pid == 913)
        #expect(!status.identity.isKnown)
    }

    @Test func identityRoundTripsThroughStatus() throws {
        var status = WallpaperStatusState()
        status.identity = identity()
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(WallpaperStatusState.self, from: data)
        #expect(decoded.identity == identity())
        #expect(decoded.identity.matches(identity()))
    }

    @Test func appexPathRecognition() {
        let hosted = "/Applications/Aerial.app/Contents/Extensions/Aerial4WallpaperExtension.appex/Contents/MacOS/Aerial4WallpaperExtension"
        #expect(WallpaperExtensionHealth.isOurAppex(path: hosted))
        #expect(!WallpaperExtensionHealth.isOurAppex(path: "/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent"))

        #expect(WallpaperExtensionHealth.isInside(path: hosted, bundlePath: "/Applications/Aerial.app"))
        #expect(!WallpaperExtensionHealth.isInside(path: "/Applications/Aerial.app.old/Contents/x", bundlePath: "/Applications/Aerial.app"))
        #expect(!WallpaperExtensionHealth.isInside(path: "/Users/x/.Trash/Aerial.app/Contents/x", bundlePath: "/Applications/Aerial.app"))
    }
}
