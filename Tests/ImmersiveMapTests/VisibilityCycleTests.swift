// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class VisibilityCycleTests: XCTestCase {
    func testProcessNextGroupsPublishesPartialBaseCollisionVisibility() {
        let cycle = VisibilityCycle(topologyGeneration: 0,
                                    cameraFingerprint: 10,
                                    horizonReservationSignature: [],
                                    viewportSize: SIMD2<Float>(200, 200),
                                    baseCount: 3,
                                    roadCount: 0,
                                    groups: [
                                        makeBaseGroup(index: 0,
                                                      position: SIMD2<Float>(50, 50),
                                                      priority: 0),
                                        makeBaseGroup(index: 1,
                                                      position: SIMD2<Float>(54, 50),
                                                      priority: 1),
                                        makeBaseGroup(index: 2,
                                                      position: SIMD2<Float>(120, 50),
                                                      priority: 2)
                                    ],
                                    cellSizePx: 32)

        cycle.processNextGroups(maxGroupCount: 1)

        XCTAssertEqual(cycle.baseCollisionVisibility, [.visible, .unknown, .unknown])
        XCTAssertFalse(cycle.isComplete)

        cycle.processNextGroups(maxGroupCount: 1)

        XCTAssertEqual(cycle.baseCollisionVisibility, [.visible, .hidden, .unknown])
        XCTAssertFalse(cycle.isComplete)
    }

    func testResolvedHiddenBaseIndicesAreAppliedOnlyOnCompletion() {
        let cycle = VisibilityCycle(topologyGeneration: 0,
                                    cameraFingerprint: 10,
                                    horizonReservationSignature: [],
                                    viewportSize: SIMD2<Float>(200, 200),
                                    baseCount: 3,
                                    roadCount: 0,
                                    groups: [
                                        makeBaseGroup(index: 0,
                                                      position: SIMD2<Float>(50, 50),
                                                      priority: 0),
                                        makeBaseGroup(index: 1,
                                                      position: SIMD2<Float>(120, 50),
                                                      priority: 1)
                                    ],
                                    resolvedHiddenBaseIndices: [2],
                                    cellSizePx: 32)

        cycle.processNextGroups(maxGroupCount: 1)

        XCTAssertEqual(cycle.baseCollisionVisibility, [.visible, .unknown, .unknown])
        XCTAssertFalse(cycle.isComplete)

        cycle.processNextGroups(maxGroupCount: 1)

        XCTAssertEqual(cycle.baseCollisionVisibility, [.visible, .visible, .hidden])
        XCTAssertTrue(cycle.isComplete)
    }

    func testResolvedHiddenBaseIndicesAreAppliedOnInitForEmptyGroups() {
        let cycle = VisibilityCycle(topologyGeneration: 0,
                                    cameraFingerprint: 10,
                                    horizonReservationSignature: [],
                                    viewportSize: SIMD2<Float>(200, 200),
                                    baseCount: 2,
                                    roadCount: 0,
                                    groups: [],
                                    resolvedHiddenBaseIndices: [0, 1],
                                    cellSizePx: 32)

        XCTAssertTrue(cycle.isComplete)
        XCTAssertEqual(cycle.baseCollisionVisibility, [.hidden, .hidden])
    }

    func testProcessNextGroupsTracksPartialRoadVisibilityResolution() {
        let cycle = VisibilityCycle(topologyGeneration: 0,
                                    cameraFingerprint: 10,
                                    horizonReservationSignature: [],
                                    viewportSize: SIMD2<Float>(200, 200),
                                    baseCount: 0,
                                    roadCount: 2,
                                    groups: [
                                        makeRoadGroup(index: 0,
                                                      position: SIMD2<Float>(50, 50),
                                                      priority: 0),
                                        makeRoadGroup(index: 1,
                                                      position: SIMD2<Float>(120, 50),
                                                      priority: 1)
                                    ],
                                    cellSizePx: 32)

        cycle.processNextGroups(maxGroupCount: 1)

        XCTAssertEqual(cycle.roadInstanceVisibility, [true, false])
        XCTAssertEqual(cycle.roadInstanceVisibilityResolved, [true, false])
        XCTAssertFalse(cycle.isComplete)
    }

    func testResolvedHiddenRoadIndicesAreMarkedResolvedOnInit() {
        let cycle = VisibilityCycle(topologyGeneration: 0,
                                    cameraFingerprint: 10,
                                    horizonReservationSignature: [],
                                    viewportSize: SIMD2<Float>(200, 200),
                                    baseCount: 0,
                                    roadCount: 3,
                                    groups: [],
                                    resolvedHiddenRoadIndices: [1],
                                    cellSizePx: 32)

        XCTAssertEqual(cycle.roadInstanceVisibility, [false, false, false])
        XCTAssertEqual(cycle.roadInstanceVisibilityResolved, [false, true, false])
    }

    func testMergingPartialBaseCollisionVisibilityKeepsPreviousForUnknown() {
        let result = BaseLabelPrepareSubsystem.mergedBaseCollisionVisibility(
            current: [.visible, .hidden, .visible],
            cycleVisibility: [.unknown, .unknown, .hidden]
        )

        XCTAssertEqual(result, [.visible, .hidden, .hidden])
    }

    func testMergingPartialBaseCollisionVisibilityHidesNewUnknownLabels() {
        let result = BaseLabelPrepareSubsystem.mergedBaseCollisionVisibility(
            current: [.visible],
            cycleVisibility: [.unknown, .visible, .unknown]
        )

        XCTAssertEqual(result, [.visible, .visible, .hidden])
    }

    func testActiveCycleIsNotReplacedWhenOnlyCameraFingerprintChanges() {
        let cycle = VisibilityCycle(topologyGeneration: 4,
                                    cameraFingerprint: 10,
                                    horizonReservationSignature: [],
                                    viewportSize: SIMD2<Float>(200, 200),
                                    baseCount: 1,
                                    roadCount: 0,
                                    groups: [
                                        makeBaseGroup(index: 0,
                                                      position: SIMD2<Float>(50, 50),
                                                      priority: 0)
                                    ],
                                    cellSizePx: 32)

        let shouldReplace = BaseLabelPrepareSubsystem.shouldReplaceActiveVisibilityCycle(
            cycle,
            latestCameraFingerprint: 11,
            forceRestart: false
        )

        XCTAssertFalse(shouldReplace)
    }

    func testStaleCameraCycleCanPublishWhenTopologyIsCurrent() {
        let cycle = VisibilityCycle(topologyGeneration: 4,
                                    cameraFingerprint: 10,
                                    horizonReservationSignature: [],
                                    viewportSize: SIMD2<Float>(200, 200),
                                    baseCount: 1,
                                    roadCount: 0,
                                    groups: [
                                        makeBaseGroup(index: 0,
                                                      position: SIMD2<Float>(50, 50),
                                                      priority: 0)
                                    ],
                                    cellSizePx: 32)

        let shouldPublish = BaseLabelPrepareSubsystem.shouldPublishVisibilityCycle(
            cycle,
            topologyGeneration: 4
        )

        XCTAssertTrue(shouldPublish)
    }

    func testCollisionOrderUsesSortPriorityBeforeStableKey() {
        let lowerSort = VisibilityCollisionGroup(target: .base(0),
                                                 members: [],
                                                 priority: 10,
                                                 secondaryPriority: 0,
                                                 sortPriority: 20,
                                                 stableOrderKey: 500)
        let higherSort = VisibilityCollisionGroup(target: .base(1),
                                                  members: [],
                                                  priority: 10,
                                                  secondaryPriority: 0,
                                                  sortPriority: 30,
                                                  stableOrderKey: 1)

        XCTAssertTrue(VisibilityCollisionGroup.sortForCollisionOrder(lhs: lowerSort, rhs: higherSort))
        XCTAssertFalse(VisibilityCollisionGroup.sortForCollisionOrder(lhs: higherSort, rhs: lowerSort))
    }

    func testCollisionOrderUsesStableKeyOnlyAfterEqualRank() {
        let first = VisibilityCollisionGroup(target: .base(10),
                                             members: [],
                                             priority: 10,
                                             secondaryPriority: 0,
                                             sortPriority: 20,
                                             stableOrderKey: 100)
        let second = VisibilityCollisionGroup(target: .base(1),
                                              members: [],
                                              priority: 10,
                                              secondaryPriority: 0,
                                              sortPriority: 20,
                                              stableOrderKey: 200)

        XCTAssertTrue(VisibilityCollisionGroup.sortForCollisionOrder(lhs: first, rhs: second))
        XCTAssertFalse(VisibilityCollisionGroup.sortForCollisionOrder(lhs: second, rhs: first))
    }

    func testCollisionOrderFallsBackToTargetOrderWhenStableKeyIsOmitted() {
        let laterBase = VisibilityCollisionGroup(target: .base(10),
                                                 members: [],
                                                 priority: 10,
                                                 secondaryPriority: 0,
                                                 sortPriority: 20)
        let earlierBase = VisibilityCollisionGroup(target: .base(1),
                                                   members: [],
                                                   priority: 10,
                                                   secondaryPriority: 0,
                                                   sortPriority: 20)
        let firstRoad = VisibilityCollisionGroup(target: .road(0),
                                                 members: [],
                                                 priority: 10,
                                                 secondaryPriority: 0,
                                                 sortPriority: 20)

        XCTAssertTrue(VisibilityCollisionGroup.sortForCollisionOrder(lhs: earlierBase, rhs: laterBase))
        XCTAssertFalse(VisibilityCollisionGroup.sortForCollisionOrder(lhs: laterBase, rhs: earlierBase))
        XCTAssertTrue(VisibilityCollisionGroup.sortForCollisionOrder(lhs: laterBase, rhs: firstRoad))
        XCTAssertFalse(VisibilityCollisionGroup.sortForCollisionOrder(lhs: firstRoad, rhs: laterBase))
    }

    func testSeededEqualRankWinnerRejectsNewOverlappingGroup() {
        let seeded = makeBaseGroup(index: 0,
                                   position: SIMD2<Float>(50, 50),
                                   priority: 10,
                                   sortPriority: 10,
                                   stableOrderKey: 100,
                                   groupId: 100)
        let newGroup = makeBaseGroup(index: 1,
                                     position: SIMD2<Float>(54, 50),
                                     priority: 10,
                                     sortPriority: 10,
                                     stableOrderKey: 200,
                                     groupId: 200)
        let cycle = VisibilityCycle(topologyGeneration: 0,
                                    cameraFingerprint: 10,
                                    horizonReservationSignature: [],
                                    viewportSize: SIMD2<Float>(200, 200),
                                    baseCount: 2,
                                    roadCount: 0,
                                    groups: [newGroup],
                                    seededGroups: [seeded],
                                    cellSizePx: 32)

        cycle.processNextGroups(maxGroupCount: 1)

        XCTAssertEqual(cycle.baseCollisionVisibility, [.unknown, .hidden])
    }

    func testHigherRankGroupEvictsSeededLowerRankWinner() {
        let seeded = makeBaseGroup(index: 0,
                                   position: SIMD2<Float>(50, 50),
                                   priority: 20,
                                   sortPriority: 10,
                                   stableOrderKey: 100,
                                   groupId: 100)
        let newGroup = makeBaseGroup(index: 1,
                                     position: SIMD2<Float>(54, 50),
                                     priority: 10,
                                     sortPriority: 10,
                                     stableOrderKey: 200,
                                     groupId: 200)
        let cycle = VisibilityCycle(topologyGeneration: 0,
                                    cameraFingerprint: 10,
                                    horizonReservationSignature: [],
                                    viewportSize: SIMD2<Float>(200, 200),
                                    baseCount: 2,
                                    roadCount: 0,
                                    groups: [newGroup],
                                    seededGroups: [seeded],
                                    cellSizePx: 32)

        cycle.processNextGroups(maxGroupCount: 1)

        XCTAssertEqual(cycle.baseCollisionVisibility, [.hidden, .visible])
    }

    func testOffscreenBaseGroupIsHidden() {
        let offscreen = makeBaseGroup(index: 0,
                                      position: SIMD2<Float>(-40, 50),
                                      priority: 0)
        let cycle = VisibilityCycle(topologyGeneration: 0,
                                    cameraFingerprint: 10,
                                    horizonReservationSignature: [],
                                    viewportSize: SIMD2<Float>(200, 200),
                                    baseCount: 1,
                                    roadCount: 0,
                                    groups: [offscreen],
                                    cellSizePx: 32)

        cycle.processNextGroups(maxGroupCount: 1)

        XCTAssertEqual(cycle.baseCollisionVisibility, [.hidden])
    }

    func testOffscreenSeededBaseGroupIsHidden() {
        let offscreen = makeBaseGroup(index: 0,
                                      position: SIMD2<Float>(-40, 50),
                                      priority: 0)
        let cycle = VisibilityCycle(topologyGeneration: 0,
                                    cameraFingerprint: 10,
                                    horizonReservationSignature: [],
                                    viewportSize: SIMD2<Float>(200, 200),
                                    baseCount: 1,
                                    roadCount: 0,
                                    groups: [offscreen],
                                    seededGroups: [offscreen],
                                    cellSizePx: 32)

        cycle.processNextGroups(maxGroupCount: 1)

        XCTAssertEqual(cycle.baseCollisionVisibility, [.hidden])
    }

    func testOffscreenSeededGroupDoesNotBlockOnscreenGroup() {
        let offscreen = makeBaseGroup(index: 0,
                                      position: SIMD2<Float>(-40, 50),
                                      priority: 0,
                                      groupId: 100)
        let onscreen = makeBaseGroup(index: 1,
                                     position: SIMD2<Float>(50, 50),
                                     priority: 0,
                                     groupId: 200)
        let cycle = VisibilityCycle(topologyGeneration: 0,
                                    cameraFingerprint: 10,
                                    horizonReservationSignature: [],
                                    viewportSize: SIMD2<Float>(200, 200),
                                    baseCount: 2,
                                    roadCount: 0,
                                    groups: [onscreen],
                                    seededGroups: [offscreen],
                                    cellSizePx: 32)

        cycle.processNextGroups(maxGroupCount: 1)

        XCTAssertEqual(cycle.baseCollisionVisibility, [.hidden, .visible])
    }

    func testOverlappingSeededEqualRankGroupsResolveToOneDeterministicWinner() {
        let first = makeBaseGroup(index: 0,
                                  position: SIMD2<Float>(50, 50),
                                  priority: 10,
                                  sortPriority: 10,
                                  stableOrderKey: 100,
                                  groupId: 100)
        let second = makeBaseGroup(index: 1,
                                   position: SIMD2<Float>(54, 50),
                                   priority: 10,
                                   sortPriority: 10,
                                   stableOrderKey: 200,
                                   groupId: 200)
        let cycle = VisibilityCycle(topologyGeneration: 0,
                                    cameraFingerprint: 10,
                                    horizonReservationSignature: [],
                                    viewportSize: SIMD2<Float>(200, 200),
                                    baseCount: 2,
                                    roadCount: 0,
                                    groups: [first, second],
                                    seededGroups: [second, first],
                                    cellSizePx: 32)

        cycle.processNextGroups(maxGroupCount: 2)

        XCTAssertEqual(cycle.baseCollisionVisibility, [.visible, .hidden])
    }

    func testSeedGroupsIncludeOnlyPublishedVisibleEnabledBaseCandidates() throws {
        let candidates = [
            ScreenCollisionCandidate(position: SIMD2<Float>(50, 50),
                                     halfSize: SIMD2<Float>(10, 10),
                                     priority: 1,
                                     secondaryPriority: 2,
                                     sortPriority: 3,
                                     stableOrderKey: 10,
                                     groupId: 10,
                                     isEnabled: true),
            ScreenCollisionCandidate(position: SIMD2<Float>(80, 50),
                                     halfSize: SIMD2<Float>(10, 10),
                                     priority: 1,
                                     secondaryPriority: 2,
                                     sortPriority: 3,
                                     stableOrderKey: 11,
                                     groupId: 11,
                                     isEnabled: false),
            ScreenCollisionCandidate(position: SIMD2<Float>(110, 50),
                                     halfSize: SIMD2<Float>(10, 10),
                                     priority: 1,
                                     secondaryPriority: 2,
                                     sortPriority: 3,
                                     stableOrderKey: 12,
                                     groupId: 12,
                                     isEnabled: true)
        ]

        let groups = BaseLabelPrepareSubsystem.makeSeededBaseCollisionGroups(
            candidates: candidates,
            visibility: [.visible, .visible, .hidden]
        )

        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.target, .base(0))
        XCTAssertEqual(group.priority, 1)
        XCTAssertEqual(group.secondaryPriority, 2)
        XCTAssertEqual(group.sortPriority, 3)
        XCTAssertEqual(group.stableOrderKey, 10)
        XCTAssertEqual(group.members.count, 1)
        XCTAssertEqual(group.members.first?.sortPriority, 3)
        XCTAssertEqual(group.members.first?.stableOrderKey, 10)
        XCTAssertEqual(group.members.first?.groupId, 10)
    }

    private func makeBaseGroup(index: Int,
                               position: SIMD2<Float>,
                               priority: Int,
                               secondaryPriority: Int = 0,
                               sortPriority: Int = 0,
                               stableOrderKey: UInt64? = nil,
                               groupId: UInt64? = nil) -> VisibilityCollisionGroup {
        let resolvedStableOrderKey = stableOrderKey ?? UInt64(index)
        let resolvedGroupId = groupId ?? resolvedStableOrderKey
        let candidate = ScreenCollisionCandidate(position: position,
                                                 halfSize: SIMD2<Float>(10, 10),
                                                 priority: priority,
                                                 secondaryPriority: secondaryPriority,
                                                 sortPriority: sortPriority,
                                                 stableOrderKey: resolvedStableOrderKey,
                                                 groupId: resolvedGroupId,
                                                 isEnabled: true)
        return VisibilityCollisionGroup(target: .base(index),
                                        members: [candidate],
                                        priority: priority,
                                        secondaryPriority: secondaryPriority,
                                        sortPriority: sortPriority,
                                        stableOrderKey: resolvedStableOrderKey)
    }

    private func makeRoadGroup(index: Int,
                               position: SIMD2<Float>,
                               priority: Int,
                               secondaryPriority: Int = 0,
                               sortPriority: Int = 0,
                               stableOrderKey: UInt64? = nil) -> VisibilityCollisionGroup {
        let resolvedStableOrderKey = stableOrderKey ?? (UInt64(index) | (1 << 63))
        let candidate = ScreenCollisionCandidate(position: position,
                                                 halfSize: SIMD2<Float>(10, 10),
                                                 priority: priority,
                                                 secondaryPriority: secondaryPriority,
                                                 sortPriority: sortPriority,
                                                 stableOrderKey: resolvedStableOrderKey,
                                                 groupId: UInt64(index + 1) | (1 << 62),
                                                 isEnabled: true)
        return VisibilityCollisionGroup(target: .road(index),
                                        members: [candidate],
                                        priority: priority,
                                        secondaryPriority: secondaryPriority,
                                        sortPriority: sortPriority,
                                        stableOrderKey: resolvedStableOrderKey)
    }
}
