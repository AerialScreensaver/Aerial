//
//  OverlayLayoutTests.swift
//  AerialTests
//
//  Tests for OverlayLayout mutation methods — pure value type operations.
//

import Testing
import Foundation
@testable import Aerial

@Suite("Overlay Layout Mutations")
struct OverlayLayoutTests {

    private func makeInstance(
        kind: OverlayKind = .clock,
        position: OverlayPosition = .bottomLeft
    ) -> OverlayInstance {
        OverlayInstance(
            id: UUID(),
            kind: kind,
            position: position,
            fontName: "Helvetica",
            fontSize: 20,
            typeSettings: [:]
        )
    }

    // MARK: - addInstance

    @Test("addInstance adds to correct position stack")
    func addInstance() {
        var layout = OverlayLayout.empty
        let instance = makeInstance(position: .topRight)
        layout.addInstance(instance)

        #expect(layout.instances(at: .topRight).count == 1)
        #expect(layout.instances(at: .topRight).first?.id == instance.id)
        #expect(layout.instances(at: .bottomLeft).isEmpty)
    }

    @Test("addInstance creates stack if new position")
    func addInstanceNewPosition() {
        var layout = OverlayLayout.empty
        let i1 = makeInstance(position: .topLeft)
        let i2 = makeInstance(position: .center)
        layout.addInstance(i1)
        layout.addInstance(i2)

        #expect(layout.stacks.count == 2)
    }

    @Test("addInstance appends to existing stack")
    func addInstanceAppendsToStack() {
        var layout = OverlayLayout.empty
        let i1 = makeInstance(position: .bottomLeft)
        let i2 = makeInstance(position: .bottomLeft)
        layout.addInstance(i1)
        layout.addInstance(i2)

        let stack = layout.instances(at: .bottomLeft)
        #expect(stack.count == 2)
        #expect(stack[0].id == i1.id)
        #expect(stack[1].id == i2.id)
    }

    // MARK: - removeInstance

    @Test("removeInstance removes from stack")
    func removeInstance() {
        var layout = OverlayLayout.empty
        let instance = makeInstance(position: .topCenter)
        layout.addInstance(instance)

        let removed = layout.removeInstance(id: instance.id)
        #expect(removed?.id == instance.id)
        #expect(layout.instances(at: .topCenter).isEmpty)
    }

    @Test("removeInstance removes empty stack from dict")
    func removeInstanceCleansUpEmptyStack() {
        var layout = OverlayLayout.empty
        let instance = makeInstance(position: .topLeft)
        layout.addInstance(instance)
        layout.removeInstance(id: instance.id)

        #expect(layout.stacks[.topLeft] == nil)
    }

    @Test("removeInstance returns nil for unknown ID")
    func removeInstanceUnknown() {
        var layout = OverlayLayout.empty
        let removed = layout.removeInstance(id: UUID())
        #expect(removed == nil)
    }

    // MARK: - moveInstance

    @Test("moveInstance: source loses entry, target gains it")
    func moveInstance() {
        var layout = OverlayLayout.empty
        let instance = makeInstance(position: .topLeft)
        layout.addInstance(instance)

        layout.moveInstance(id: instance.id, to: .bottomRight, at: 0)

        #expect(layout.instances(at: .topLeft).isEmpty)
        #expect(layout.instances(at: .bottomRight).count == 1)
        #expect(layout.instances(at: .bottomRight).first?.position == .bottomRight)
    }

    // MARK: - insertInstance

    @Test("insertInstance respects clamped index")
    func insertInstanceClamped() {
        var layout = OverlayLayout.empty
        let i1 = makeInstance(position: .bottomCenter)
        let i2 = makeInstance(position: .bottomCenter)
        layout.addInstance(i1)

        // Insert at index 100 — should clamp to end
        layout.insertInstance(i2, at: 100)
        let stack = layout.instances(at: .bottomCenter)
        #expect(stack.count == 2)
        #expect(stack[1].id == i2.id)
    }

    @Test("insertInstance at 0 prepends")
    func insertInstanceAtZero() {
        var layout = OverlayLayout.empty
        let i1 = makeInstance(position: .topRight)
        let i2 = makeInstance(position: .topRight)
        layout.addInstance(i1)
        layout.insertInstance(i2, at: 0)

        let stack = layout.instances(at: .topRight)
        #expect(stack[0].id == i2.id)
        #expect(stack[1].id == i1.id)
    }

    @Test("insertInstance creates stack if needed")
    func insertInstanceCreatesStack() {
        var layout = OverlayLayout.empty
        let instance = makeInstance(position: .center)
        layout.insertInstance(instance, at: 0)

        #expect(layout.instances(at: .center).count == 1)
    }

    // MARK: - updateInstance

    @Test("updateInstance replaces in-place")
    func updateInstanceInPlace() {
        var layout = OverlayLayout.empty
        var instance = makeInstance(position: .bottomLeft)
        layout.addInstance(instance)

        instance.fontSize = 99
        layout.updateInstance(instance)

        #expect(layout.instances(at: .bottomLeft).first?.fontSize == 99)
    }

    @Test("updateInstance handles position change")
    func updateInstancePositionChange() {
        var layout = OverlayLayout.empty
        var instance = makeInstance(position: .topLeft)
        layout.addInstance(instance)

        instance.position = .bottomRight
        layout.updateInstance(instance)

        #expect(layout.instances(at: .topLeft).isEmpty)
        #expect(layout.instances(at: .bottomRight).count == 1)
    }

    // MARK: - allInstances

    @Test("allInstances returns flattened list")
    func allInstances() {
        var layout = OverlayLayout.empty
        let i1 = makeInstance(position: .topLeft)
        let i2 = makeInstance(position: .bottomRight)
        let i3 = makeInstance(position: .topLeft)
        layout.addInstance(i1)
        layout.addInstance(i2)
        layout.addInstance(i3)

        let all = layout.allInstances
        #expect(all.count == 3)
        let ids = Set(all.map { $0.id })
        #expect(ids.contains(i1.id))
        #expect(ids.contains(i2.id))
        #expect(ids.contains(i3.id))
    }

    // MARK: - instance(withID:)

    @Test("instance(withID:) finds by UUID")
    func instanceByID() {
        var layout = OverlayLayout.empty
        let instance = makeInstance(position: .center)
        layout.addInstance(instance)

        #expect(layout.instance(withID: instance.id)?.id == instance.id)
    }

    @Test("instance(withID:) returns nil for unknown")
    func instanceByIDUnknown() {
        let layout = OverlayLayout.empty
        #expect(layout.instance(withID: UUID()) == nil)
    }
}
