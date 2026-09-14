//
//  CacheTrimPlannerTests.swift
//  AerialTests
//
//  Pure planner behind Settings → "Trim Cache to Limit": tiers, ordering,
//  protection, and the stop condition.
//

import Testing
@testable import Aerial

@Suite("Cache trim planner")
struct CacheTrimPlannerTests {

    private typealias C = CacheTrimPlanner.Candidate
    private let gb = 1_000_000_000

    private func plan(current: Int, target: Int, _ candidates: [C], protecting: Set<String> = []) -> CacheTrimPlanner.Result {
        CacheTrimPlanner.plan(currentBytes: current, targetBytes: target, candidates: candidates, protecting: protecting)
    }

    @Test("already under target: nothing to delete")
    func underTarget() {
        let result = plan(current: 10 * gb, target: 20 * gb, [C(id: "a", bytes: gb, isHidden: false, inRotation: false, order: 0)])
        #expect(result.ids.isEmpty)
        #expect(result.bytes == 0)
        #expect(result.reachedTarget == true)
    }

    @Test("hidden videos go first, even when small")
    func hiddenFirst() {
        let result = plan(current: 30 * gb, target: 29 * gb, [
            C(id: "old-visible", bytes: 5 * gb, isHidden: false, inRotation: false, order: 0),
            C(id: "hidden", bytes: gb / 10, isHidden: true, inRotation: false, order: 5),
        ])
        #expect(result.ids.first == "hidden")
    }

    @Test("out of rotation before in rotation, oldest first within a tier")
    func tiersAndOrder() {
        let result = plan(current: 40 * gb, target: 10 * gb, [
            C(id: "rot-old", bytes: 5 * gb, isHidden: false, inRotation: true, order: 0),
            C(id: "free-new", bytes: 5 * gb, isHidden: false, inRotation: false, order: 3),
            C(id: "free-old", bytes: 5 * gb, isHidden: false, inRotation: false, order: 1),
            C(id: "rot-new", bytes: 5 * gb, isHidden: false, inRotation: true, order: 4),
        ])
        #expect(result.ids == ["free-old", "free-new", "rot-old", "rot-new"])
        #expect(result.reachedTarget == false)   // 40 − 20 = 20 > 10
    }

    @Test("stops at the first candidate that brings the size under target")
    func stopsEarly() {
        let result = plan(current: 22 * gb, target: 20 * gb, [
            C(id: "a", bytes: gb, isHidden: false, inRotation: false, order: 0),
            C(id: "b", bytes: gb, isHidden: false, inRotation: false, order: 1),
            C(id: "c", bytes: gb, isHidden: false, inRotation: false, order: 2),
        ])
        #expect(result.ids == ["a", "b"])
        #expect(result.bytes == 2 * gb)
        #expect(result.reachedTarget == true)
    }

    @Test("protected ids are never selected, even when they are the only way under target")
    func protectedSkipped() {
        let result = plan(current: 22 * gb, target: 20 * gb, [
            C(id: "playing", bytes: 5 * gb, isHidden: false, inRotation: false, order: 0),
            C(id: "small", bytes: gb, isHidden: false, inRotation: false, order: 1),
        ], protecting: ["playing"])
        #expect(result.ids == ["small"])
        #expect(result.reachedTarget == false)
    }

    @Test("equal ranks keep input order")
    func stableOnTies() {
        let result = plan(current: 30 * gb, target: 0, [
            C(id: "x", bytes: gb, isHidden: false, inRotation: false, order: 0),
            C(id: "y", bytes: gb, isHidden: false, inRotation: false, order: 0),
        ])
        #expect(result.ids == ["x", "y"])
    }
}
