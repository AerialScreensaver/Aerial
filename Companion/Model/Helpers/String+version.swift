//
//  String+version.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 03/08/2020.
//

import Foundation

extension String {

    // Modified from the DragonCherry extension - https://github.com/DragonCherry/VersionCompare
    private func compare(toVersion targetVersion: String) -> ComparisonResult {
        let versionDelimiter = "."
        var result: ComparisonResult = .orderedSame
        var versionComponents = components(separatedBy: versionDelimiter).compactMap(Double.init).map { String($0) }
        var targetComponents = targetVersion.components(separatedBy: versionDelimiter).compactMap(Double.init).map { String($0) }


        while versionComponents.count < targetComponents.count {
            versionComponents.append("0")
        }

        while targetComponents.count < versionComponents.count {
            targetComponents.append("0")
        }

        for (version, target) in zip(versionComponents, targetComponents) {
            result = version.compare(target, options: .numeric)
            if result != .orderedSame {
                break
            }
        }

        return result
    }

    func isVersion(equalTo targetVersion: String) -> Bool { return compare(toVersion: targetVersion) == .orderedSame }

    func isVersion(greaterThan targetVersion: String) -> Bool { return compare(toVersion: targetVersion) == .orderedDescending }

    func isVersion(greaterThanOrEqualTo targetVersion: String) -> Bool { return compare(toVersion: targetVersion) != .orderedAscending }

    func isVersion(lessThan targetVersion: String) -> Bool { return compare(toVersion: targetVersion) == .orderedAscending }

    func isVersion(lessThanOrEqualTo targetVersion: String) -> Bool { return compare(toVersion: targetVersion) != .orderedDescending }

    static func ===(lhs: String, rhs: String) -> Bool { lhs.compare(toVersion: rhs) == .orderedSame }

    static func <(lhs: String, rhs: String) -> Bool { lhs.compare(toVersion: rhs) == .orderedAscending }

    static func <=(lhs: String, rhs: String) -> Bool { lhs.compare(toVersion: rhs) != .orderedDescending }

    static func >(lhs: String, rhs: String) -> Bool { lhs.compare(toVersion: rhs) == .orderedDescending }

    static func >=(lhs: String, rhs: String) -> Bool { lhs.compare(toVersion: rhs) != .orderedAscending }

}
