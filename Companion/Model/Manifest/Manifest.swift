//
//  Manifest.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 24/07/2020.
//

import Foundation

// MARK: - Manifest
struct Manifest: Codable {
    let alphaVersion, alphaSHA256: String?  // This will go away soon
    let updaterVersion, betaVersion, betaSHA256: String
    let releaseVersion, releaseSHA256: String
}

// MARK: Manifest convenience initializers and mutators

extension Manifest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Manifest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

/*    func with(
        updaterVersion: String? = nil,
        alphaVersion: String? = nil,
        alphaSHA256: String? = nil,
        betaVersion: String? = nil,
        betaSHA256: String? = nil,
        releaseVersion: String? = nil,
        releaseSHA256: String? = nil
    ) -> Manifest {
        return Manifest(
            updaterVersion: updaterVersion ?? self.updaterVersion,
            alphaVersion: alphaVersion ?? self.alphaVersion,
            alphaSHA256: alphaSHA256 ?? self.alphaSHA256,
            betaVersion: betaVersion ?? self.betaVersion,
            betaSHA256: betaSHA256 ?? self.betaSHA256,
            releaseVersion: releaseVersion ?? self.releaseVersion,
            releaseSHA256: releaseSHA256 ?? self.releaseSHA256
        )
    }*/

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Helper functions for creating encoders and decoders

func newJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    if #available(iOS 10.0, OSX 10.12, tvOS 10.0, watchOS 3.0, *) {
        decoder.dateDecodingStrategy = .iso8601
    }
    return decoder
}

func newJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    if #available(iOS 10.0, OSX 10.12, tvOS 10.0, watchOS 3.0, *) {
        encoder.dateEncodingStrategy = .iso8601
    }
    return encoder
}
