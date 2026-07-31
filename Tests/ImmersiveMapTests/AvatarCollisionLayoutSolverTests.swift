// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

final class AvatarCollisionLayoutSolverTests: XCTestCase {
    /// Test geometry: pin body of radius 50, visible circle 46, body center
    /// 55px above the anchor.
    private static let geometry = AvatarCollisionGeometry(markerSizePx: 100.0,
                                                          bodyRadiusPx: 50.0,
                                                          circleBodyRadiusPx: 46.0,
                                                          bodyCenterOffsetPx: 55.0)

    // MARK: - Displacement and shape

    func testLoneMarkerStaysAtAnchorAsFullSizedPin() throws {
        let solver = AvatarCollisionLayoutSolver()
        let layout = solver.solve(projectedMarkers: [try Self.makeProjected(id: 1, position: SIMD2(400, 300))],
                                  geometry: Self.geometry,
                                  config: Self.makeConfig(),
                                  time: 0)

        XCTAssertEqual(layout.markerItems.count, 1)
        let item = try XCTUnwrap(layout.markerItems.first)
        XCTAssertEqual(item.screenPoint.position, SIMD2(400, 300))
        XCTAssertEqual(item.displayScale, 1.0)
        XCTAssertEqual(item.morph, 0.0)
        XCTAssertFalse(layout.hasActiveAnimations)
    }

    func testDisplacedMarkersBecomeSmallerCircles() throws {
        let config = Self.makeConfig()
        let solver = AvatarCollisionLayoutSolver()
        let markers = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(415, 300)),
            try Self.makeProjected(id: 3, position: SIMD2(400, 315))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        // Three or more packed tight: no dominant, all show as circles
        // noticeably smaller than a pin, within [compressedScale, displacedCircleScale].
        for item in layout.markerItems {
            XCTAssertEqual(item.morph, 1.0, accuracy: 0.01)
            XCTAssertLessThanOrEqual(item.displayScale, AvatarCollisionMath.displacedCircleScale + 0.001)
            XCTAssertGreaterThanOrEqual(item.displayScale, config.compressedScale - 0.001)
        }
        try Self.assertNoBodyOverlaps(layout: layout, config: config)
    }

    func testPairKeepsDominantPinAndYieldsCircle() throws {
        // A pair of touching markers: one keeps its normal shape in place,
        // the other turns into a circle and moves away.
        let config = Self.makeConfig()
        let solver = AvatarCollisionLayoutSolver()
        let markers = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(460, 300))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        let dominant = try XCTUnwrap(layout.markerItems.first { $0.marker.id == 1 })
        let yielding = try XCTUnwrap(layout.markerItems.first { $0.marker.id == 2 })
        XCTAssertEqual(dominant.screenPoint.position, SIMD2(400, 300))
        XCTAssertEqual(dominant.morph, 0.0)
        XCTAssertEqual(dominant.displayScale, 1.0)
        XCTAssertEqual(yielding.morph, 1.0, accuracy: 0.01)
        XCTAssertLessThanOrEqual(yielding.displayScale, AvatarCollisionMath.displacedCircleScale + 0.001)
        XCTAssertGreaterThan(simd_length(yielding.screenPoint.position - yielding.anchorScreenPoint.position), 10.0)
        try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 2.0)
    }

    func testYieldingCircleTouchesDominantWithoutGap() throws {
        // A gap between markers is not allowed: the yielding circle sits flush
        // against the dominant (by visible body radii, gap < 1.5px).
        let config = Self.makeConfig()
        let solver = AvatarCollisionLayoutSolver()
        let markers = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(440, 300))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        let dominant = try XCTUnwrap(layout.markerItems.first { $0.marker.id == 1 })
        let yielding = try XCTUnwrap(layout.markerItems.first { $0.marker.id == 2 })
        let distance = simd_length(Self.bodyCenter(of: dominant) - Self.bodyCenter(of: yielding))
        let touching = Self.geometry.bodyRadius(morph: dominant.morph) * dominant.displayScale
            + Self.geometry.bodyRadius(morph: yielding.morph) * yielding.displayScale
        XCTAssertEqual(distance, touching, accuracy: 1.5)
    }

    func testPinReactsOnlyToActualCircleBodyNotFullSizeGhost() throws {
        // Zoom-out case: a neighbor has already yielded to the dominant and
        // become a circle. A third marker whose full body would intersect the
        // neighbor's FULL body, but not its actual circle, must stay a pin in
        // place: the circle does not "push" from the distance of its former
        // full radius.
        // A column of two components: pair {1, 2} (dominant + yielding circle
        // sliding down) and a separate id3 whose anchored body does not touch
        // id2's anchored body. In pass A the full body of the displaced id2
        // presses into id3, but id2's actual circle does not reach it.
        let config = Self.makeConfig()
        let solver = AvatarCollisionLayoutSolver()
        let markers = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(400, 380)),
            try Self.makeProjected(id: 3, position: SIMD2(400, 505))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        let dominant = try XCTUnwrap(layout.markerItems.first { $0.marker.id == 1 })
        let yielded = try XCTUnwrap(layout.markerItems.first { $0.marker.id == 2 })
        let bystander = try XCTUnwrap(layout.markerItems.first { $0.marker.id == 3 })
        XCTAssertEqual(dominant.morph, 0.0)
        XCTAssertEqual(yielded.morph, 1.0, accuracy: 0.01)
        // The witness is untouched: a full pin exactly on its geo point.
        XCTAssertEqual(bystander.morph, 0.0, accuracy: 0.05)
        XCTAssertEqual(bystander.displayScale, 1.0, accuracy: 0.01)
        XCTAssertEqual(bystander.screenPoint.position, SIMD2(400, 505))
        try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 2.0)
    }

    func testThreeCloseMarkersAllBecomeCircles() throws {
        // Requirement: three avatars packed tight all show as circles, with no
        // "primary" pin with a daisy around it.
        let config = Self.makeConfig()
        let solver = AvatarCollisionLayoutSolver()
        let markers = try (1...3).map { id in
            try Self.makeProjected(id: UInt64(id), position: SIMD2(400, 300))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        XCTAssertEqual(layout.markerItems.count, 3)
        for item in layout.markerItems {
            XCTAssertEqual(item.morph, 1.0, accuracy: 0.01)
            XCTAssertLessThanOrEqual(item.displayScale, AvatarCollisionMath.displacedCircleScale + 0.001)
            XCTAssertGreaterThan(simd_length(item.screenPoint.position - item.anchorScreenPoint.position), 5.0)
        }
        try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 1.5)
    }

    func testMarkersDoNotReactBeforeBodiesTouch() throws {
        // Physicality: until full-size bodies touch, nobody compresses or
        // moves. Bodies of radius 50 with centers 55 above the anchors:
        // an anchor distance of 101 leaves a 1px gap.
        let config = Self.makeConfig()
        let solver = AvatarCollisionLayoutSolver()
        let markers = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(501, 300))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        for item in layout.markerItems {
            XCTAssertEqual(item.screenPoint.position, item.anchorScreenPoint.position)
            XCTAssertEqual(item.displayScale, 1.0)
            XCTAssertEqual(item.morph, 0.0)
        }
    }

    func testCrowdCompressesCirclesDownToLimitOnly() throws {
        // A crowd with a clamped maxOffsetPx: circles compress by different
        // amounts, but never below the compressedScale limit.
        var config = Self.makeConfig()
        config.maxOffsetPx = 60.0
        let solver = AvatarCollisionLayoutSolver()
        var markers = try (1...6).map { id in
            try Self.makeProjected(id: UInt64(id), position: SIMD2(400, 300))
        }
        markers.append(try Self.makeProjected(id: 99, position: SIMD2(900, 300)))
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        let lone = try XCTUnwrap(layout.markerItems.first { $0.marker.id == 99 })
        XCTAssertEqual(lone.displayScale, 1.0)
        XCTAssertEqual(lone.morph, 0.0)
        for item in layout.markerItems where item.marker.id != 99 {
            XCTAssertLessThan(item.displayScale, AvatarCollisionMath.displacedCircleScale + 0.001)
            XCTAssertGreaterThanOrEqual(item.displayScale, config.compressedScale - 0.001)
        }
    }

    func testMixedPinAndCircleBodiesDoNotOverlap() throws {
        // A selected full-size pin against displaced circles: bodies are offset
        // from their anchors differently; the solver must separate the body centers themselves.
        let config = Self.makeConfig()
        let solver = AvatarCollisionLayoutSolver()
        let markers = try (1...6).map { id in
            try Self.makeProjected(id: UInt64(id),
                                   position: SIMD2(400 + Float(id), 300),
                                   isSelected: id == 1)
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        let selected = try XCTUnwrap(layout.markerItems.first { $0.marker.id == 1 })
        XCTAssertEqual(selected.displayScale, 1.0)
        XCTAssertEqual(selected.morph, 0.0)
        for item in layout.markerItems where item.marker.id != 1 {
            XCTAssertLessThanOrEqual(item.displayScale, AvatarCollisionMath.displacedCircleScale + 0.001)
        }
        try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 3.0)
    }

    func testSelectedMarkerIsImmovableAndFullSized() throws {
        let solver = AvatarCollisionLayoutSolver()
        let markers = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300), isSelected: true),
            try Self.makeProjected(id: 2, position: SIMD2(408, 300))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: Self.makeConfig())

        let selected = try XCTUnwrap(layout.markerItems.first { $0.marker.id == 1 })
        let other = try XCTUnwrap(layout.markerItems.first { $0.marker.id == 2 })
        XCTAssertEqual(selected.screenPoint.position, SIMD2(400, 300))
        XCTAssertEqual(selected.displayScale, 1.0)
        XCTAssertEqual(selected.morph, 0.0)
        XCTAssertGreaterThan(simd_length(other.screenPoint.position - other.anchorScreenPoint.position), 1.0)
        try Self.assertNoBodyOverlaps(layout: layout, config: Self.makeConfig(), tolerance: 3.0)
    }

    func testSpringReturnsMarkerToPinWhenNeighborDisappears() throws {
        let solver = AvatarCollisionLayoutSolver()
        var time: TimeInterval = 0
        _ = try Self.solveUntilSettled(solver: solver,
                                       markers: [
                                           try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
                                           try Self.makeProjected(id: 2, position: SIMD2(410, 300))
                                       ],
                                       config: Self.makeConfig(),
                                       time: &time)

        // Dominant id 1 disappeared: the yielding circle id 2 returns to its
        // geo point and becomes a full-size pin again.
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: [try Self.makeProjected(id: 2, position: SIMD2(410, 300))],
                                                config: Self.makeConfig(),
                                                time: &time)

        let item = try XCTUnwrap(layout.markerItems.first)
        XCTAssertEqual(item.screenPoint.position, SIMD2(410, 300))
        XCTAssertEqual(item.displayScale, 1.0)
        XCTAssertEqual(item.morph, 0.0)
    }

    func testDisplacementIsClampedByMaxOffset() throws {
        var config = Self.makeConfig()
        config.maxOffsetPx = 30.0
        let solver = AvatarCollisionLayoutSolver()
        let markers = try (1...5).map { id in
            try Self.makeProjected(id: UInt64(id), position: SIMD2(400, 300))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        // maxOffsetPx limits body displacement: body centers are compared.
        for item in layout.markerItems {
            let displacedCenter = Self.bodyCenter(of: item)
            let restingCenter = item.anchorScreenPoint.position
                + SIMD2<Float>(0.0, Self.geometry.bodyCenterOffsetPx * item.marker.screenSizeScale)
            XCTAssertLessThanOrEqual(simd_length(displacedCenter - restingCenter),
                                     config.maxOffsetPx + Self.geometry.bodyCenterOffsetPx + 1.0)
        }
    }

    func testCoincidentMarkersSeparateDeterministically() throws {
        func run() throws -> AvatarCollisionLayout {
            let solver = AvatarCollisionLayoutSolver()
            return try Self.solveUntilSettled(solver: solver,
                                              markers: [
                                                  try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
                                                  try Self.makeProjected(id: 2, position: SIMD2(400, 300))
                                              ],
                                              config: Self.makeConfig())
        }

        let first = try run()
        let second = try run()

        try Self.assertNoBodyOverlaps(layout: first, config: Self.makeConfig())
        let dominant = try XCTUnwrap(first.markerItems.first { $0.marker.id == 1 })
        XCTAssertEqual(dominant.screenPoint.position, SIMD2(400, 300))
        for (lhs, rhs) in zip(first.markerItems, second.markerItems) {
            XCTAssertEqual(lhs.marker.id, rhs.marker.id)
            XCTAssertEqual(lhs.screenPoint.position, rhs.screenPoint.position)
            XCTAssertFalse(lhs.screenPoint.position.x.isNaN)
            XCTAssertFalse(lhs.screenPoint.position.y.isNaN)
        }
    }

    func testConvergedLayoutMatchesAcrossFrameRates() throws {
        func converge(stepSeconds: TimeInterval) throws -> AvatarCollisionLayout {
            let solver = AvatarCollisionLayoutSolver()
            let markers = [
                try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
                try Self.makeProjected(id: 2, position: SIMD2(412, 300))
            ]
            var time: TimeInterval = 0
            var layout = AvatarCollisionLayout.empty
            for _ in 0..<1200 {
                layout = solver.solve(projectedMarkers: markers,
                                      geometry: Self.geometry,
                                      config: Self.makeConfig(),
                                      time: time)
                if layout.hasActiveAnimations == false {
                    return layout
                }
                time += stepSeconds
            }
            XCTFail("Solver did not settle")
            return layout
        }

        let at60 = try converge(stepSeconds: 1.0 / 60.0)
        let at30 = try converge(stepSeconds: 1.0 / 30.0)
        for (lhs, rhs) in zip(at60.markerItems, at30.markerItems) {
            XCTAssertLessThan(simd_length(lhs.screenPoint.position - rhs.screenPoint.position), 1.5)
            XCTAssertEqual(lhs.displayScale, rhs.displayScale, accuracy: 0.02)
        }
    }

    func testBorderlineContactSettlesWithoutSizeOscillation() throws {
        // The paradoxical zone: full-size bodies barely lack room while
        // circles fit with margin. Previously the node radius depended on the
        // smoothed morph and the marker jittered pin <-> circle forever. The
        // targets are solved by a two-pass scheme and must converge to a fixed point.
        let config = Self.makeConfig()
        let solver = AvatarCollisionLayoutSolver()
        let markers = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(505, 300))
        ]
        var time: TimeInterval = 0
        let settled = try Self.solveUntilSettled(solver: solver,
                                                 markers: markers,
                                                 config: config,
                                                 time: &time)

        for _ in 0..<120 {
            time += 1.0 / 60.0
            let layout = solver.solve(projectedMarkers: markers,
                                      geometry: Self.geometry,
                                      config: config,
                                      time: time)
            XCTAssertFalse(layout.hasActiveAnimations)
            for (item, settledItem) in zip(layout.markerItems, settled.markerItems) {
                XCTAssertEqual(item.displayScale, settledItem.displayScale, accuracy: 0.001)
                XCTAssertEqual(item.morph, settledItem.morph, accuracy: 0.001)
                XCTAssertLessThan(simd_length(item.screenPoint.position - settledItem.screenPoint.position), 0.1)
            }
        }
        try Self.assertNoBodyOverlaps(layout: settled, config: config, tolerance: 3.0)
    }

    func testTransientFramesNeverShowBodyOverlaps() throws {
        // An abrupt rearrangement (anchors teleport right next to each other):
        // smoothing lags behind the targets, but the final pass must resolve
        // overlaps of the displayed bodies in EVERY frame, not only after convergence.
        let config = Self.makeConfig()
        let solver = AvatarCollisionLayoutSolver()
        var time: TimeInterval = 0
        _ = try Self.solveUntilSettled(solver: solver,
                                       markers: [
                                           try Self.makeProjected(id: 1, position: SIMD2(200, 300)),
                                           try Self.makeProjected(id: 2, position: SIMD2(700, 300)),
                                           try Self.makeProjected(id: 3, position: SIMD2(450, 700))
                                       ],
                                       config: config,
                                       time: &time)

        let piled = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(408, 300)),
            try Self.makeProjected(id: 3, position: SIMD2(400, 308))
        ]
        for _ in 0..<240 {
            time += 1.0 / 60.0
            let layout = solver.solve(projectedMarkers: piled,
                                      geometry: Self.geometry,
                                      config: config,
                                      time: time)
            try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 1.0)
        }
    }

    func testAnchorJumpCarriesOffsetsWithoutSpike() throws {
        let solver = AvatarCollisionLayoutSolver()
        var time: TimeInterval = 0
        let settled = try Self.solveUntilSettled(solver: solver,
                                                 markers: [
                                                     try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
                                                     try Self.makeProjected(id: 2, position: SIMD2(412, 300))
                                                 ],
                                                 config: Self.makeConfig(),
                                                 time: &time)
        let offsetsBefore = Dictionary(uniqueKeysWithValues: settled.markerItems.map {
            ($0.marker.id, $0.screenPoint.position - $0.anchorScreenPoint.position)
        })

        // Anchor teleport (analogous to jumping across the world wrap seam):
        // offsets are stored relative to the anchor and must not spike.
        time += 1.0 / 60.0
        let jumped = solver.solve(projectedMarkers: [
                                      try Self.makeProjected(id: 1, position: SIMD2(5400, 300)),
                                      try Self.makeProjected(id: 2, position: SIMD2(5412, 300))
                                  ],
                                  geometry: Self.geometry,
                                  config: Self.makeConfig(),
                                  time: time)

        for item in jumped.markerItems {
            let offset = item.screenPoint.position - item.anchorScreenPoint.position
            let before = try XCTUnwrap(offsetsBefore[item.marker.id])
            XCTAssertLessThan(simd_length(offset - before), 1.0)
        }
    }

    // MARK: - Flower cluster

    func testEventPolicyPairFormsTwoPetalFlower() throws {
        let solver = AvatarCollisionLayoutSolver()
        let markers = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300), clusterPolicy: .event),
            try Self.makeProjected(id: 2, position: SIMD2(480, 300), clusterPolicy: .event)
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: Self.makeConfig())

        XCTAssertEqual(layout.flowerGroups.count, 1)
        let group = try XCTUnwrap(layout.flowerGroups.first)
        XCTAssertEqual(group.memberIDs, [1, 2])
        XCTAssertEqual(group.visibleMemberIDs, [1, 2])
        XCTAssertEqual(layout.markerItems.count, 2)
        for item in layout.markerItems {
            XCTAssertEqual(item.morph, 1.0, accuracy: 0.01)
            XCTAssertEqual(item.screenPoint.visibilityAlpha, 1.0, accuracy: 0.01)
        }
    }

    func testFlowerShowsPetalsAndHidesOverflowMembers() throws {
        var config = Self.makeConfig()
        config.groupingThreshold = 10
        let solver = AvatarCollisionLayoutSolver()
        let markers = try (1...12).map { id in
            try Self.makeProjected(id: UInt64(id),
                                   position: SIMD2(400 + Float(id) * 0.5, 300))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        XCTAssertEqual(layout.flowerGroups.count, 1)
        let group = try XCTUnwrap(layout.flowerGroups.first)
        XCTAssertEqual(group.memberIDs.count, 12)
        XCTAssertEqual(group.visibleMemberIDs.count, AvatarCollisionMath.maxFlowerPetals)
        // Members that do not fit are not shown at all.
        XCTAssertEqual(layout.markerItems.count, AvatarCollisionMath.maxFlowerPetals)

        // Petals stand on the flower ring as circles at minimum scale.
        let petalBodyRadius = Self.geometry.circleBodyRadiusPx * config.compressedScale
        let ringRadius = AvatarCollisionMath.flowerRingRadius(petalBodyRadius: petalBodyRadius,
                                                              petalCount: AvatarCollisionMath.maxFlowerPetals)
        for item in layout.markerItems {
            XCTAssertEqual(item.displayScale, config.compressedScale, accuracy: 0.01)
            XCTAssertEqual(item.morph, 1.0, accuracy: 0.01)
            let distance = simd_length(Self.bodyCenter(of: item) - group.center)
            XCTAssertEqual(distance, ringRadius, accuracy: 2.0)
        }
    }

    func testPetalsHoldSlotsUnderCrowdPressure() throws {
        // A dense crowd around the flower: the final correction must not
        // push petals out of their slots (petals are immovable; only free
        // circles yield).
        var config = Self.makeConfig()
        config.groupingThreshold = 2
        let solver = AvatarCollisionLayoutSolver()
        var markers = try (1...4).map { id in
            try Self.makeProjected(id: UInt64(id),
                                   position: SIMD2(400 + Float(id) * 0.5, 300))
        }
        for (index, angle) in [0.0, 1.57, 3.14, 4.71].enumerated() {
            let position = SIMD2<Float>(400 + cos(Float(angle)) * 70.0,
                                        300 + sin(Float(angle)) * 70.0)
            markers.append(try Self.makeProjected(id: UInt64(50 + index), position: position))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        let group = try XCTUnwrap(layout.flowerGroups.first)
        let petalBodyRadius = Self.geometry.circleBodyRadiusPx * config.compressedScale
        let ringRadius = AvatarCollisionMath.flowerRingRadius(petalBodyRadius: petalBodyRadius,
                                                              petalCount: group.visibleMemberIDs.count)
        for item in layout.markerItems where item.isFlowerPetal {
            let distance = simd_length(Self.bodyCenter(of: item) - group.center)
            XCTAssertEqual(distance, ringRadius, accuracy: 1.0,
                           "Лепесток \(item.marker.id) выбит из слота")
        }
    }

    func testTenPiledMarkersFormFlowerWithDefaultSettings() throws {
        // A pile noticeably larger than the default threshold collapses into a
        // flower rather than a chaotic heap of free circles; extra members are hidden.
        var config = ImmersiveMapSettings.default.avatars
        config.smoothing = 0.35
        let solver = AvatarCollisionLayoutSolver()
        let markers = try (1...10).map { id in
            try Self.makeProjected(id: UInt64(id),
                                   position: SIMD2(400 + Float(id) * 0.5, 300))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        XCTAssertEqual(layout.flowerGroups.count, 1)
        let group = try XCTUnwrap(layout.flowerGroups.first)
        XCTAssertEqual(group.memberIDs.count, 10)
        XCTAssertEqual(group.visibleMemberIDs.count, AvatarCollisionMath.maxFlowerPetals)
        XCTAssertEqual(layout.markerItems.count, AvatarCollisionMath.maxFlowerPetals)
    }

    func testDefaultGroupingBoundaryIsFiveMarkers() throws {
        // Default grouping boundary: a pile of five collapses into a flower;
        // four packed tight remain free circles with no cluster.
        var config = ImmersiveMapSettings.default.avatars
        config.smoothing = 0.35
        XCTAssertEqual(config.groupingThreshold, 5)

        func solvePile(count: Int) throws -> AvatarCollisionLayout {
            let solver = AvatarCollisionLayoutSolver()
            let markers = try (1...count).map { id in
                try Self.makeProjected(id: UInt64(id),
                                       position: SIMD2(400 + Float(id) * 0.5, 300))
            }
            return try Self.solveUntilSettled(solver: solver,
                                              markers: markers,
                                              config: config)
        }

        let five = try solvePile(count: 5)
        XCTAssertEqual(five.flowerGroups.count, 1)
        XCTAssertEqual(five.flowerGroups.first?.memberIDs.count, 5)
        XCTAssertEqual(five.flowerGroups.first?.visibleMemberIDs.count, 5)
        XCTAssertEqual(five.markerItems.count, 5)

        let four = try solvePile(count: 4)
        XCTAssertTrue(four.flowerGroups.isEmpty)
        XCTAssertEqual(four.markerItems.count, 4)
        try Self.assertNoBodyOverlaps(layout: four, config: config, tolerance: 1.5)
    }

    func testGroupingHysteresisKeepsFlowerBetweenEnterAndExitRadii() throws {
        var config = Self.makeConfig()
        config.groupingThreshold = 1
        let solver = AvatarCollisionLayoutSolver()
        var time: TimeInterval = 0
        // enterR = 35, exitR = 45.5 at markerSizePx = 100.

        func solveOnce(distance: Float) throws -> AvatarCollisionLayout {
            time += 1.0 / 60.0
            return solver.solve(projectedMarkers: [
                                    try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
                                    try Self.makeProjected(id: 2, position: SIMD2(400 + distance, 300))
                                ],
                                geometry: Self.geometry,
                                config: config,
                                time: time)
        }

        XCTAssertTrue(try solveOnce(distance: 41).flowerGroups.isEmpty,
                      "41px > enterR: пара не должна группироваться")
        XCTAssertEqual(try solveOnce(distance: 30).flowerGroups.count, 1,
                       "30px <= enterR: пара группируется в цветок")
        XCTAssertEqual(try solveOnce(distance: 41).flowerGroups.count, 1,
                       "41px <= exitR: цветок держится (гистерезис)")
        XCTAssertTrue(try solveOnce(distance: 60).flowerGroups.isEmpty,
                      "60px > exitR: цветок распадается")
    }

    func testSelectedMarkerJoinsFlowerAsVisiblePetal() throws {
        var config = Self.makeConfig()
        config.groupingThreshold = 1
        let solver = AvatarCollisionLayoutSolver()
        let markers = [
            try Self.makeProjected(id: 5, position: SIMD2(400, 300), isSelected: true),
            try Self.makeProjected(id: 2, position: SIMD2(402, 300)),
            try Self.makeProjected(id: 3, position: SIMD2(404, 300))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        XCTAssertEqual(layout.flowerGroups.count, 1)
        let group = try XCTUnwrap(layout.flowerGroups.first)
        XCTAssertEqual(group.memberIDs, [2, 3, 5])
        // The selected member is guaranteed among visible petals and comes first.
        XCTAssertEqual(group.visibleMemberIDs.first, 5)
        XCTAssertEqual(layout.markerItems.count, 3)
    }

    func testFlowerStaysPutAndNeighborsReactOnlyToPetalTouch() throws {
        var config = Self.makeConfig()
        config.groupingThreshold = 2
        let solver = AvatarCollisionLayoutSolver()
        // The trio forms a flower with the centroid at (400, 300.67). Neighbor
        // id 8 actually touches the nearest petal; neighbor id 9 only falls
        // inside the ring's invisible circumscribed circle and must not be touched.
        let markers = [
            try Self.makeProjected(id: 1, position: SIMD2(398, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(402, 300)),
            try Self.makeProjected(id: 3, position: SIMD2(400, 302)),
            try Self.makeProjected(id: 8, position: SIMD2(440, 300)),
            try Self.makeProjected(id: 9, position: SIMD2(475, 380))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        XCTAssertEqual(layout.flowerGroups.count, 1)
        let group = try XCTUnwrap(layout.flowerGroups.first)
        XCTAssertEqual(group.memberIDs, [1, 2, 3])
        // The cluster stands on the centroid of its anchors: neighbors do not move it.
        XCTAssertLessThan(simd_length(group.center - SIMD2(400.0, 300.6666)), 0.01)
        // The neighbor touching a petal yields: displaced and turned into a circle.
        let touching = try XCTUnwrap(layout.markerItems.first { $0.marker.id == 8 })
        XCTAssertGreaterThan(simd_length(touching.screenPoint.position - touching.anchorScreenPoint.position), 5.0)
        XCTAssertGreaterThan(touching.morph, 0.5)
        // The neighbor inside the circumscribed circle but away from the petals: an untouched pin.
        let bystander = try XCTUnwrap(layout.markerItems.first { $0.marker.id == 9 })
        XCTAssertEqual(bystander.screenPoint.position, SIMD2(475, 380))
        XCTAssertEqual(bystander.morph, 0.0, accuracy: 0.05)
        XCTAssertEqual(bystander.displayScale, 1.0, accuracy: 0.01)
    }

    func testOverlappingFlowersMergeIntoOne() throws {
        // Two flowers are immovable and cannot yield to each other: ring
        // overlap is resolved by merging into a single flower.
        var config = Self.makeConfig()
        config.groupingThreshold = 2
        let solver = AvatarCollisionLayoutSolver()
        var markers: [AvatarProjectedMarker] = []
        for id in 1...3 {
            markers.append(try Self.makeProjected(id: UInt64(id),
                                                  position: SIMD2(400 + Float(id), 300)))
        }
        for id in 11...13 {
            markers.append(try Self.makeProjected(id: UInt64(id),
                                                  position: SIMD2(460 + Float(id), 300)))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        XCTAssertEqual(layout.flowerGroups.count, 1)
        XCTAssertEqual(layout.flowerGroups.first?.memberIDs.count, 6)
        try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 1.5)
    }

    func testSelectedTouchingFlowerJoinsItAsPetal() throws {
        // The selected marker's anchor is outside the grouping radius, but its
        // immovable body touches the flower ring: the conflict of two rigid
        // bodies is resolved by including the selected one in the flower as the first petal.
        var config = Self.makeConfig()
        config.groupingThreshold = 2
        let solver = AvatarCollisionLayoutSolver()
        let markers = [
            try Self.makeProjected(id: 1, position: SIMD2(398, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(402, 300)),
            try Self.makeProjected(id: 3, position: SIMD2(400, 302)),
            try Self.makeProjected(id: 9, position: SIMD2(470, 300), isSelected: true)
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        XCTAssertEqual(layout.flowerGroups.count, 1)
        let group = try XCTUnwrap(layout.flowerGroups.first)
        XCTAssertEqual(group.memberIDs, [1, 2, 3, 9])
        XCTAssertEqual(group.visibleMemberIDs.first, 9)
        try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 1.5)
    }

    func testMarkerAnchoredInsideRingIsAbsorbed() throws {
        // The marker's anchor is inside the flower ring: the spring would pull
        // it into the flower forever, so it is absorbed by the pile.
        var config = Self.makeConfig()
        config.groupingThreshold = 2
        let solver = AvatarCollisionLayoutSolver()
        let markers = [
            try Self.makeProjected(id: 1, position: SIMD2(398, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(402, 300)),
            try Self.makeProjected(id: 3, position: SIMD2(400, 302)),
            try Self.makeProjected(id: 9, position: SIMD2(400, 320))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        XCTAssertEqual(layout.flowerGroups.count, 1)
        XCTAssertEqual(layout.flowerGroups.first?.memberIDs, [1, 2, 3, 9])
    }

    func testHiddenFlowerMembersReappearAfterBreakup() throws {
        var config = Self.makeConfig()
        config.groupingThreshold = 3
        let solver = AvatarCollisionLayoutSolver()
        var time: TimeInterval = 0
        let piledMarkers = try (1...9).map { id in
            try Self.makeProjected(id: UInt64(id),
                                   position: SIMD2(400 + Float(id) * 0.5, 300))
        }
        let piled = try Self.solveUntilSettled(solver: solver,
                                               markers: piledMarkers,
                                               config: config,
                                               time: &time)
        XCTAssertEqual(piled.markerItems.count, AvatarCollisionMath.maxFlowerPetals)

        // Anchors fly apart: the flower disbands, hidden members return.
        let spreadMarkers = try (1...9).map { id in
            try Self.makeProjected(id: UInt64(id),
                                   position: SIMD2(Float(id) * 400.0, 300))
        }
        let spread = try Self.solveUntilSettled(solver: solver,
                                                markers: spreadMarkers,
                                                config: config,
                                                time: &time)
        XCTAssertTrue(spread.flowerGroups.isEmpty)
        XCTAssertEqual(spread.markerItems.count, 9)
    }

    // MARK: - Cluster locality

    func testSprawlingChainSplitsIntoLocalFlowers() throws {
        // A marker chain spanning half the screen is pairwise connected, but a
        // cluster must be local: an overgrown component is cut by the world
        // grid, and each member's anchor stays near its ring (previously the
        // chain collapsed into one flower with cones across the whole screen).
        var config = Self.makeConfig()
        config.groupingThreshold = 3
        let solver = AvatarCollisionLayoutSolver()
        let markers = try (0..<17).map { step in
            try Self.makeProjected(id: UInt64(step + 1),
                                   position: SIMD2(400.0 + Float(step) * 30.0, 300.0))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        let compactnessLimit = Self.geometry.markerSizePx * AvatarCollisionMath.flowerCompactnessLimitScale
        XCTAssertGreaterThan(layout.flowerGroups.count, 1, "Переросток не разрезан")
        var coveredMembers = 0
        for group in layout.flowerGroups {
            coveredMembers += group.memberIDs.count
            for memberID in group.memberIDs {
                let anchor = SIMD2<Float>(400.0 + Float(memberID - 1) * 30.0, 300.0)
                XCTAssertLessThan(simd_length(anchor - group.center), compactnessLimit,
                                  "Якорь участника \(memberID) далеко от кольца своего кластера")
            }
        }
        XCTAssertEqual(coveredMembers, 17)
        try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 1.5)
    }

    func testWorldGridSplitIsStableUnderPan(){
        // Panning shifts screen positions while world positions stay fixed:
        // the composition of the cut clusters must not be rebuilt (the grid is
        // anchored to the world, not the screen).
        var config = Self.makeConfig()
        config.groupingThreshold = 3

        func flowerCompositions(panOffset: SIMD2<Float>) throws -> [[UInt64]] {
            let solver = AvatarCollisionLayoutSolver()
            let markers = try (0..<17).map { step -> AvatarProjectedMarker in
                let basePosition = SIMD2(400.0 + Float(step) * 30.0, 300.0)
                return try Self.makeProjected(id: UInt64(step + 1),
                                              position: basePosition + panOffset,
                                              worldPosition: SIMD2(Double(basePosition.x) * 0.001,
                                                                   Double(basePosition.y) * 0.001))
            }
            return try Self.solveUntilSettled(solver: solver,
                                              markers: markers,
                                              config: config)
                .flowerGroups.map(\.memberIDs)
        }

        XCTAssertNoThrow(try {
            let still = try flowerCompositions(panOffset: .zero)
            let panned = try flowerCompositions(panOffset: SIMD2(37.0, 53.0))
            XCTAssertEqual(still, panned, "Пан пересобрал составы кластеров")
        }())
    }

    func testUnmergeableIntersectingRingsSeparateWithoutOverlap() throws {
        // A dense five and a long chain nearby: their rings intersect, but
        // merging is forbidden by the compactness limit. The rings are pushed
        // apart: the smaller group yields, petals of the two flowers do not overlap.
        var config = Self.makeConfig()
        config.groupingThreshold = 2
        let solver = AvatarCollisionLayoutSolver()
        var markers: [AvatarProjectedMarker] = []
        for id in 1...5 {
            markers.append(try Self.makeProjected(id: UInt64(id),
                                                  position: SIMD2(400.0 + Float(id) * 0.5, 300.0)))
        }
        for step in 0..<9 {
            markers.append(try Self.makeProjected(id: UInt64(20 + step),
                                                  position: SIMD2(450.0, 315.0 + Float(step) * 30.0)))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        XCTAssertEqual(layout.flowerGroups.count, 2, "Кластеры слились, хотя лимит компактности должен запрещать")
        let small = try XCTUnwrap(layout.flowerGroups.first { $0.memberIDs.count == 5 })
        let large = try XCTUnwrap(layout.flowerGroups.first { $0.memberIDs.count == 9 })
        // The large one stands on the centroid of its anchors; the small one yielded.
        XCTAssertLessThan(simd_length(large.center - SIMD2<Float>(450.0, 435.0)), 1.0)
        XCTAssertGreaterThan(simd_length(small.center - SIMD2<Float>(401.5, 300.0)), 1.0)
        try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 1.5)
    }

    func testDenseMosaicOfFlowersHasNoPetalOverlaps() throws {
        // A solid dense field: the cut yields a mosaic of adjacent flowers
        // whose rings lack area. Petals of different clusters must be pushed
        // apart by the final correction: a petal-petal overlap (both
        // "immovable") used to freeze forever.
        var config = Self.makeConfig()
        config.groupingThreshold = 5
        let solver = AvatarCollisionLayoutSolver()
        var generatorState: UInt64 = 7
        func random() -> Float {
            generatorState = generatorState &* 6364136223846793005 &+ 1442695040888963407
            return Float(generatorState >> 40) / Float(UInt64.max >> 40)
        }
        let markers = try (1...800).map { id -> AvatarProjectedMarker in
            let angle = random() * 2.0 * .pi
            let radius = 600.0 * random().squareRoot()
            return try Self.makeProjected(id: UInt64(id),
                                          position: SIMD2(900.0 + cos(angle) * radius,
                                                          450.0 + sin(angle) * radius * 0.5))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                markers: markers,
                                                config: config)

        XCTAssertGreaterThan(layout.flowerGroups.count, 3, "Плотное поле должно дать мозаику кластеров")
        try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 1.5)
    }

    // MARK: - Helpers

    private static func makeConfig() -> ImmersiveMapSettings.AvatarSettings {
        var config = ImmersiveMapSettings.default.avatars
        config.collisionPaddingPx = 0.0
        config.maxOffsetPx = 220.0
        config.collisionIterations = 10
        config.springK = 0.25
        config.smoothing = 0.35
        config.compressedScale = 0.55
        config.groupingThreshold = 10
        return config
    }

    private static func bodyCenter(of item: AvatarCollisionMarkerItem) -> SIMD2<Float> {
        item.screenPoint.position
            + SIMD2<Float>(0.0, geometry.bodyCenterOffsetPx * item.displayScale * item.marker.screenSizeScale)
    }

    private static func solveUntilSettled(solver: AvatarCollisionLayoutSolver,
                                          markers: [AvatarProjectedMarker],
                                          config: ImmersiveMapSettings.AvatarSettings) throws -> AvatarCollisionLayout {
        var time: TimeInterval = 0
        return try solveUntilSettled(solver: solver,
                                     markers: markers,
                                     config: config,
                                     time: &time)
    }

    private static func solveUntilSettled(solver: AvatarCollisionLayoutSolver,
                                          markers: [AvatarProjectedMarker],
                                          config: ImmersiveMapSettings.AvatarSettings,
                                          time: inout TimeInterval) throws -> AvatarCollisionLayout {
        var layout = AvatarCollisionLayout.empty
        for iteration in 0..<1200 {
            layout = solver.solve(projectedMarkers: markers,
                                  geometry: geometry,
                                  config: config,
                                  time: time)
            if layout.hasActiveAnimations == false, iteration > 0 {
                return layout
            }
            time += 1.0 / 60.0
        }
        XCTFail("Solver did not settle within the iteration budget")
        return layout
    }

    /// Verifies the absence of visual overlaps: centers and radii of the
    /// actual (compressed) bodies are compared.
    private static func assertNoBodyOverlaps(layout: AvatarCollisionLayout,
                                             config: ImmersiveMapSettings.AvatarSettings,
                                             tolerance: Float = 1.0,
                                             file: StaticString = #filePath,
                                             line: UInt = #line) throws {
        func bodyRadius(of item: AvatarCollisionMarkerItem) -> Float {
            geometry.bodyRadius(morph: item.morph) * item.displayScale * item.marker.screenSizeScale
        }

        for lhsIndex in layout.markerItems.indices {
            for rhsIndex in (lhsIndex + 1)..<layout.markerItems.count {
                let lhs = layout.markerItems[lhsIndex]
                let rhs = layout.markerItems[rhsIndex]
                let distance = simd_length(bodyCenter(of: lhs) - bodyCenter(of: rhs))
                XCTAssertGreaterThanOrEqual(distance,
                                            bodyRadius(of: lhs) + bodyRadius(of: rhs) - tolerance,
                                            "Тела маркеров \(lhs.marker.id) и \(rhs.marker.id) пересекаются",
                                            file: file,
                                            line: line)
            }
        }
    }

    private static func makeProjected(id: UInt64,
                                      position: SIMD2<Float>,
                                      isSelected: Bool = false,
                                      clusterPolicy: AvatarClusterPolicy = .none,
                                      visibilityAlpha: Float = 1.0,
                                      worldPosition: SIMD2<Double>? = nil) throws -> AvatarProjectedMarker {
        AvatarProjectedMarker(marker: try makeMarker(id: id,
                                                     isSelected: isSelected,
                                                     clusterPolicy: clusterPolicy),
                              squashScale: SIMD2<Float>(repeating: 1),
                              screenPoint: ScreenPointOutput(position: position,
                                                             depth: 0.5,
                                                             visible: 1,
                                                             visibilityAlpha: visibilityAlpha),
                              worldPosition: worldPosition,
                              drawOrder: Int(id))
    }

    private static func makeMarker(id: UInt64,
                                   isSelected: Bool,
                                   clusterPolicy: AvatarClusterPolicy) throws -> AvatarMarker {
        AvatarMarker(id: id,
                     coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                     image: try makeTestImage(),
                     isSelected: isSelected,
                     clusterPolicy: clusterPolicy)
    }

    private static func makeTestImage() throws -> CGImage {
        let bytesPerRow = 4
        var data = Data(repeating: 0xff, count: bytesPerRow)
        let image = data.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(data: baseAddress,
                                          width: 1,
                                          height: 1,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            return context.makeImage()
        }
        return try XCTUnwrap(image)
    }
}
