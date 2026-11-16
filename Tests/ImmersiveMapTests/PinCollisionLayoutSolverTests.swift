// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

final class PinCollisionLayoutSolverTests: XCTestCase {
    /// A map whose pins do not spread apart leaves each on its coordinate,
    /// at full size and with no beam, in its draw order.
    func testAnchoredPinsStandOnTheirCoordinatesInDrawOrder() throws {
        func projected(id: UInt64, x: Float, drawOrder: Int) throws -> ProjectedPin {
            ProjectedPin(pin: ImmersiveMapPin(id: id,
                                              coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                                              image: try Self.onePixelImage()),
                         squashScale: SIMD2<Float>(1, 1),
                         screenPoint: ScreenPointOutput(position: SIMD2<Float>(x, 100), depth: 0, visible: 1, visibilityAlpha: 1),
                         worldPosition: .zero,
                         drawOrder: drawOrder)
        }
        // Two pins on the same pixel: with spreading they would be pushed apart.
        let layout = PinCollisionLayout.anchored([try projected(id: 2, x: 50, drawOrder: 1),
                                                  try projected(id: 1, x: 50, drawOrder: 0)])

        XCTAssertEqual(layout.pinItems.map(\.pin.id), [1, 2])
        XCTAssertFalse(layout.hasActiveAnimations)
        for item in layout.pinItems {
            XCTAssertEqual(item.screenPoint.position, SIMD2<Float>(50, 100))
            XCTAssertEqual(item.anchorScreenPoint.position, item.screenPoint.position, "No pin is off its place")
            XCTAssertEqual(item.displayScale, 1)
            XCTAssertEqual(item.morph, 0)
        }
    }

    private static func onePixelImage() throws -> CGImage {
        var data = Data(repeating: 0xff, count: 4)
        let image = data.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let base = bytes.baseAddress,
                  let context = CGContext(data: base, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            return context.makeImage()
        }
        return try XCTUnwrap(image)
    }

    /// Test geometry: pin body of radius 50, visible circle 46, body center
    /// 55px above the anchor.
    private static let geometry = PinCollisionGeometry(pinSizePx: 100.0,
                                                          bodyRadiusPx: 50.0,
                                                          circleBodyRadiusPx: 46.0,
                                                          bodyCenterOffsetPx: SIMD2<Float>(0.0, 55.0))

    // MARK: - Displacement and shape

    func testLonePinStaysAtAnchorAsFullSizedPin() throws {
        let solver = PinCollisionLayoutSolver()
        let layout = solver.solve(projectedPins: [try Self.makeProjected(id: 1, position: SIMD2(400, 300))],
                                  geometry: Self.geometry,
                                  config: Self.makeConfig(),
                                  time: 0)

        XCTAssertEqual(layout.pinItems.count, 1)
        let item = try XCTUnwrap(layout.pinItems.first)
        XCTAssertEqual(item.screenPoint.position, SIMD2(400, 300))
        XCTAssertEqual(item.displayScale, 1.0)
        XCTAssertEqual(item.morph, 0.0)
        XCTAssertFalse(layout.hasActiveAnimations)
    }

    func testDisplacedPinsBecomeSmallerCircles() throws {
        let config = Self.makeConfig()
        let solver = PinCollisionLayoutSolver()
        let pins = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(415, 300)),
            try Self.makeProjected(id: 3, position: SIMD2(400, 315))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        // Three or more packed tight: no dominant, all show as circles
        // noticeably smaller than a pin, within [compressedScale, displacedCircleScale].
        for item in layout.pinItems {
            XCTAssertEqual(item.morph, 1.0, accuracy: 0.01)
            XCTAssertLessThanOrEqual(item.displayScale, PinCollisionMath.displacedCircleScale + 0.001)
            XCTAssertGreaterThanOrEqual(item.displayScale, config.compressedScale - 0.001)
        }
        try Self.assertNoBodyOverlaps(layout: layout, config: config)
    }

    func testPairKeepsDominantPinAndYieldsCircle() throws {
        // A pair of touching pins: one keeps its normal shape in place,
        // the other turns into a circle and moves away.
        let config = Self.makeConfig()
        let solver = PinCollisionLayoutSolver()
        let pins = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(460, 300))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        let dominant = try XCTUnwrap(layout.pinItems.first { $0.pin.id == 1 })
        let yielding = try XCTUnwrap(layout.pinItems.first { $0.pin.id == 2 })
        XCTAssertEqual(dominant.screenPoint.position, SIMD2(400, 300))
        XCTAssertEqual(dominant.morph, 0.0)
        XCTAssertEqual(dominant.displayScale, 1.0)
        XCTAssertEqual(yielding.morph, 1.0, accuracy: 0.01)
        XCTAssertLessThanOrEqual(yielding.displayScale, PinCollisionMath.displacedCircleScale + 0.001)
        XCTAssertGreaterThan(simd_length(yielding.screenPoint.position - yielding.anchorScreenPoint.position), 10.0)
        try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 2.0)
    }

    func testYieldingCircleTouchesDominantWithoutGap() throws {
        // A gap between pins is not allowed: the yielding circle sits flush
        // against the dominant (by visible body radii, gap < 1.5px).
        let config = Self.makeConfig()
        let solver = PinCollisionLayoutSolver()
        let pins = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(440, 300))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        let dominant = try XCTUnwrap(layout.pinItems.first { $0.pin.id == 1 })
        let yielding = try XCTUnwrap(layout.pinItems.first { $0.pin.id == 2 })
        let distance = simd_length(Self.bodyCenter(of: dominant) - Self.bodyCenter(of: yielding))
        let touching = Self.geometry.bodyRadius(morph: dominant.morph) * dominant.displayScale
            + Self.geometry.bodyRadius(morph: yielding.morph) * yielding.displayScale
        XCTAssertEqual(distance, touching, accuracy: 1.5)
    }

    func testPinReactsOnlyToActualCircleBodyNotFullSizeGhost() throws {
        // Zoom-out case: a neighbor has already yielded to the dominant and
        // become a circle. A third pin whose full body would intersect the
        // neighbor's FULL body, but not its actual circle, must stay a pin in
        // place: the circle does not "push" from the distance of its former
        // full radius.
        // A column of two components: pair {1, 2} (dominant + yielding circle
        // sliding down) and a separate id3 whose anchored body does not touch
        // id2's anchored body. In pass A the full body of the displaced id2
        // presses into id3, but id2's actual circle does not reach it.
        let config = Self.makeConfig()
        let solver = PinCollisionLayoutSolver()
        let pins = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(400, 380)),
            try Self.makeProjected(id: 3, position: SIMD2(400, 505))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        let dominant = try XCTUnwrap(layout.pinItems.first { $0.pin.id == 1 })
        let yielded = try XCTUnwrap(layout.pinItems.first { $0.pin.id == 2 })
        let bystander = try XCTUnwrap(layout.pinItems.first { $0.pin.id == 3 })
        XCTAssertEqual(dominant.morph, 0.0)
        XCTAssertEqual(yielded.morph, 1.0, accuracy: 0.01)
        // The witness is untouched: a full pin exactly on its geo point.
        XCTAssertEqual(bystander.morph, 0.0, accuracy: 0.05)
        XCTAssertEqual(bystander.displayScale, 1.0, accuracy: 0.01)
        XCTAssertEqual(bystander.screenPoint.position, SIMD2(400, 505))
        try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 2.0)
    }

    func testThreeClosePinsAllBecomeCircles() throws {
        // Requirement: three pins packed tight all show as circles, with no
        // "primary" pin with a daisy around it.
        let config = Self.makeConfig()
        let solver = PinCollisionLayoutSolver()
        let pins = try (1...3).map { id in
            try Self.makeProjected(id: UInt64(id), position: SIMD2(400, 300))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        XCTAssertEqual(layout.pinItems.count, 3)
        for item in layout.pinItems {
            XCTAssertEqual(item.morph, 1.0, accuracy: 0.01)
            XCTAssertLessThanOrEqual(item.displayScale, PinCollisionMath.displacedCircleScale + 0.001)
            XCTAssertGreaterThan(simd_length(item.screenPoint.position - item.anchorScreenPoint.position), 5.0)
        }
        try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 1.5)
    }

    func testPinsDoNotReactBeforeBodiesTouch() throws {
        // Physicality: until full-size bodies touch, nobody compresses or
        // moves. Bodies of radius 50 with centers 55 above the anchors:
        // an anchor distance of 101 leaves a 1px gap.
        let config = Self.makeConfig()
        let solver = PinCollisionLayoutSolver()
        let pins = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(501, 300))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        for item in layout.pinItems {
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
        let solver = PinCollisionLayoutSolver()
        var pins = try (1...6).map { id in
            try Self.makeProjected(id: UInt64(id), position: SIMD2(400, 300))
        }
        pins.append(try Self.makeProjected(id: 99, position: SIMD2(900, 300)))
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        let lone = try XCTUnwrap(layout.pinItems.first { $0.pin.id == 99 })
        XCTAssertEqual(lone.displayScale, 1.0)
        XCTAssertEqual(lone.morph, 0.0)
        for item in layout.pinItems where item.pin.id != 99 {
            XCTAssertLessThan(item.displayScale, PinCollisionMath.displacedCircleScale + 0.001)
            XCTAssertGreaterThanOrEqual(item.displayScale, config.compressedScale - 0.001)
        }
    }

    func testMixedPinAndCircleBodiesDoNotOverlap() throws {
        // A selected full-size pin against displaced circles: bodies are offset
        // from their anchors differently; the solver must separate the body centers themselves.
        let config = Self.makeConfig()
        let solver = PinCollisionLayoutSolver()
        let pins = try (1...6).map { id in
            try Self.makeProjected(id: UInt64(id),
                                   position: SIMD2(400 + Float(id), 300),
                                   isSelected: id == 1)
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        let selected = try XCTUnwrap(layout.pinItems.first { $0.pin.id == 1 })
        XCTAssertEqual(selected.displayScale, 1.0)
        XCTAssertEqual(selected.morph, 0.0)
        for item in layout.pinItems where item.pin.id != 1 {
            XCTAssertLessThanOrEqual(item.displayScale, PinCollisionMath.displacedCircleScale + 0.001)
        }
        try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 3.0)
    }

    func testSelectedPinIsImmovableAndFullSized() throws {
        let solver = PinCollisionLayoutSolver()
        let pins = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300), isSelected: true),
            try Self.makeProjected(id: 2, position: SIMD2(408, 300))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: Self.makeConfig())

        let selected = try XCTUnwrap(layout.pinItems.first { $0.pin.id == 1 })
        let other = try XCTUnwrap(layout.pinItems.first { $0.pin.id == 2 })
        XCTAssertEqual(selected.screenPoint.position, SIMD2(400, 300))
        XCTAssertEqual(selected.displayScale, 1.0)
        XCTAssertEqual(selected.morph, 0.0)
        XCTAssertGreaterThan(simd_length(other.screenPoint.position - other.anchorScreenPoint.position), 1.0)
        try Self.assertNoBodyOverlaps(layout: layout, config: Self.makeConfig(), tolerance: 3.0)
    }

    func testSpringReturnsPinToPinWhenNeighborDisappears() throws {
        let solver = PinCollisionLayoutSolver()
        var time: TimeInterval = 0
        _ = try Self.solveUntilSettled(solver: solver,
                                       pins: [
                                           try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
                                           try Self.makeProjected(id: 2, position: SIMD2(410, 300))
                                       ],
                                       config: Self.makeConfig(),
                                       time: &time)

        // Dominant id 1 disappeared: the yielding circle id 2 returns to its
        // geo point and becomes a full-size pin again.
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: [try Self.makeProjected(id: 2, position: SIMD2(410, 300))],
                                                config: Self.makeConfig(),
                                                time: &time)

        let item = try XCTUnwrap(layout.pinItems.first)
        XCTAssertEqual(item.screenPoint.position, SIMD2(410, 300))
        XCTAssertEqual(item.displayScale, 1.0)
        XCTAssertEqual(item.morph, 0.0)
    }

    func testDisplacementIsClampedByMaxOffset() throws {
        var config = Self.makeConfig()
        config.maxOffsetPx = 30.0
        let solver = PinCollisionLayoutSolver()
        let pins = try (1...5).map { id in
            try Self.makeProjected(id: UInt64(id), position: SIMD2(400, 300))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        // maxOffsetPx limits body displacement: body centers are compared.
        for item in layout.pinItems {
            let displacedCenter = Self.bodyCenter(of: item)
            let restingCenter = item.anchorScreenPoint.position
                + Self.geometry.bodyCenterOffsetPx * item.pin.screenSizeScale
            XCTAssertLessThanOrEqual(simd_length(displacedCenter - restingCenter),
                                     config.maxOffsetPx + Self.geometry.bodyCenterOffsetPx.y + 1.0)
        }
    }

    func testCoincidentPinsSeparateDeterministically() throws {
        func run() throws -> PinCollisionLayout {
            let solver = PinCollisionLayoutSolver()
            return try Self.solveUntilSettled(solver: solver,
                                              pins: [
                                                  try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
                                                  try Self.makeProjected(id: 2, position: SIMD2(400, 300))
                                              ],
                                              config: Self.makeConfig())
        }

        let first = try run()
        let second = try run()

        try Self.assertNoBodyOverlaps(layout: first, config: Self.makeConfig())
        let dominant = try XCTUnwrap(first.pinItems.first { $0.pin.id == 1 })
        XCTAssertEqual(dominant.screenPoint.position, SIMD2(400, 300))
        for (lhs, rhs) in zip(first.pinItems, second.pinItems) {
            XCTAssertEqual(lhs.pin.id, rhs.pin.id)
            XCTAssertEqual(lhs.screenPoint.position, rhs.screenPoint.position)
            XCTAssertFalse(lhs.screenPoint.position.x.isNaN)
            XCTAssertFalse(lhs.screenPoint.position.y.isNaN)
        }
    }

    func testConvergedLayoutMatchesAcrossFrameRates() throws {
        func converge(stepSeconds: TimeInterval) throws -> PinCollisionLayout {
            let solver = PinCollisionLayoutSolver()
            let pins = [
                try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
                try Self.makeProjected(id: 2, position: SIMD2(412, 300))
            ]
            var time: TimeInterval = 0
            var layout = PinCollisionLayout.empty
            for _ in 0..<1200 {
                layout = solver.solve(projectedPins: pins,
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
        for (lhs, rhs) in zip(at60.pinItems, at30.pinItems) {
            XCTAssertLessThan(simd_length(lhs.screenPoint.position - rhs.screenPoint.position), 1.5)
            XCTAssertEqual(lhs.displayScale, rhs.displayScale, accuracy: 0.02)
        }
    }

    func testBorderlineContactSettlesWithoutSizeOscillation() throws {
        // The paradoxical zone: full-size bodies barely lack room while
        // circles fit with margin. Previously the node radius depended on the
        // smoothed morph and the pin jittered pin <-> circle forever. The
        // targets are solved by a two-pass scheme and must converge to a fixed point.
        let config = Self.makeConfig()
        let solver = PinCollisionLayoutSolver()
        let pins = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(505, 300))
        ]
        var time: TimeInterval = 0
        let settled = try Self.solveUntilSettled(solver: solver,
                                                 pins: pins,
                                                 config: config,
                                                 time: &time)

        for _ in 0..<120 {
            time += 1.0 / 60.0
            let layout = solver.solve(projectedPins: pins,
                                      geometry: Self.geometry,
                                      config: config,
                                      time: time)
            XCTAssertFalse(layout.hasActiveAnimations)
            for (item, settledItem) in zip(layout.pinItems, settled.pinItems) {
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
        let solver = PinCollisionLayoutSolver()
        var time: TimeInterval = 0
        _ = try Self.solveUntilSettled(solver: solver,
                                       pins: [
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
            let layout = solver.solve(projectedPins: piled,
                                      geometry: Self.geometry,
                                      config: config,
                                      time: time)
            try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 1.0)
        }
    }

    func testAnchorJumpCarriesOffsetsWithoutSpike() throws {
        let solver = PinCollisionLayoutSolver()
        var time: TimeInterval = 0
        let settled = try Self.solveUntilSettled(solver: solver,
                                                 pins: [
                                                     try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
                                                     try Self.makeProjected(id: 2, position: SIMD2(412, 300))
                                                 ],
                                                 config: Self.makeConfig(),
                                                 time: &time)
        let offsetsBefore = Dictionary(uniqueKeysWithValues: settled.pinItems.map {
            ($0.pin.id, $0.screenPoint.position - $0.anchorScreenPoint.position)
        })

        // Anchor teleport (analogous to jumping across the world wrap seam):
        // offsets are stored relative to the anchor and must not spike.
        time += 1.0 / 60.0
        let jumped = solver.solve(projectedPins: [
                                      try Self.makeProjected(id: 1, position: SIMD2(5400, 300)),
                                      try Self.makeProjected(id: 2, position: SIMD2(5412, 300))
                                  ],
                                  geometry: Self.geometry,
                                  config: Self.makeConfig(),
                                  time: time)

        for item in jumped.pinItems {
            let offset = item.screenPoint.position - item.anchorScreenPoint.position
            let before = try XCTUnwrap(offsetsBefore[item.pin.id])
            XCTAssertLessThan(simd_length(offset - before), 1.0)
        }
    }

    // MARK: - Flower cluster

    func testEventPolicyPairFormsTwoPetalFlower() throws {
        let solver = PinCollisionLayoutSolver()
        let pins = [
            try Self.makeProjected(id: 1, position: SIMD2(400, 300), clusterPolicy: .event),
            try Self.makeProjected(id: 2, position: SIMD2(480, 300), clusterPolicy: .event)
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: Self.makeConfig())

        XCTAssertEqual(layout.flowerGroups.count, 1)
        let group = try XCTUnwrap(layout.flowerGroups.first)
        XCTAssertEqual(group.memberIDs, [1, 2])
        XCTAssertEqual(group.visibleMemberIDs, [1, 2])
        XCTAssertEqual(layout.pinItems.count, 2)
        for item in layout.pinItems {
            XCTAssertEqual(item.morph, 1.0, accuracy: 0.01)
            XCTAssertEqual(item.screenPoint.visibilityAlpha, 1.0, accuracy: 0.01)
        }
    }

    func testFlowerShowsPetalsAndHidesOverflowMembers() throws {
        var config = Self.makeConfig()
        config.groupingThreshold = 10
        let solver = PinCollisionLayoutSolver()
        let pins = try (1...12).map { id in
            try Self.makeProjected(id: UInt64(id),
                                   position: SIMD2(400 + Float(id) * 0.5, 300))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        XCTAssertEqual(layout.flowerGroups.count, 1)
        let group = try XCTUnwrap(layout.flowerGroups.first)
        XCTAssertEqual(group.memberIDs.count, 12)
        XCTAssertEqual(group.visibleMemberIDs.count, PinCollisionMath.maxFlowerPetals)
        // Members that do not fit are not shown at all.
        XCTAssertEqual(layout.pinItems.count, PinCollisionMath.maxFlowerPetals)

        // Petals stand on the flower ring as circles at minimum scale.
        let petalBodyRadius = Self.geometry.circleBodyRadiusPx * config.compressedScale
        let ringRadius = PinCollisionMath.flowerRingRadius(petalBodyRadius: petalBodyRadius,
                                                              petalCount: PinCollisionMath.maxFlowerPetals)
        for item in layout.pinItems {
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
        let solver = PinCollisionLayoutSolver()
        var pins = try (1...4).map { id in
            try Self.makeProjected(id: UInt64(id),
                                   position: SIMD2(400 + Float(id) * 0.5, 300))
        }
        for (index, angle) in [0.0, 1.57, 3.14, 4.71].enumerated() {
            let position = SIMD2<Float>(400 + cos(Float(angle)) * 70.0,
                                        300 + sin(Float(angle)) * 70.0)
            pins.append(try Self.makeProjected(id: UInt64(50 + index), position: position))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        let group = try XCTUnwrap(layout.flowerGroups.first)
        let petalBodyRadius = Self.geometry.circleBodyRadiusPx * config.compressedScale
        let ringRadius = PinCollisionMath.flowerRingRadius(petalBodyRadius: petalBodyRadius,
                                                              petalCount: group.visibleMemberIDs.count)
        for item in layout.pinItems where item.isFlowerPetal {
            let distance = simd_length(Self.bodyCenter(of: item) - group.center)
            XCTAssertEqual(distance, ringRadius, accuracy: 1.0,
                           "Petal \(item.pin.id) was knocked out of its slot")
        }
    }

    func testTenPiledPinsFormFlowerWithDefaultSettings() throws {
        // A pile noticeably larger than the default threshold collapses into a
        // flower rather than a chaotic heap of free circles; extra members are hidden.
        var config = ImmersiveMapSettings.default.pins
        config.smoothing = 0.35
        let solver = PinCollisionLayoutSolver()
        let pins = try (1...10).map { id in
            try Self.makeProjected(id: UInt64(id),
                                   position: SIMD2(400 + Float(id) * 0.5, 300))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        XCTAssertEqual(layout.flowerGroups.count, 1)
        let group = try XCTUnwrap(layout.flowerGroups.first)
        XCTAssertEqual(group.memberIDs.count, 10)
        XCTAssertEqual(group.visibleMemberIDs.count, PinCollisionMath.maxFlowerPetals)
        XCTAssertEqual(layout.pinItems.count, PinCollisionMath.maxFlowerPetals)
    }

    func testDefaultGroupingBoundaryIsFivePins() throws {
        // Default grouping boundary: a pile of five collapses into a flower;
        // four packed tight remain free circles with no cluster.
        var config = ImmersiveMapSettings.default.pins
        config.smoothing = 0.35
        XCTAssertEqual(config.groupingThreshold, 5)

        func solvePile(count: Int) throws -> PinCollisionLayout {
            let solver = PinCollisionLayoutSolver()
            let pins = try (1...count).map { id in
                try Self.makeProjected(id: UInt64(id),
                                       position: SIMD2(400 + Float(id) * 0.5, 300))
            }
            return try Self.solveUntilSettled(solver: solver,
                                              pins: pins,
                                              config: config)
        }

        let five = try solvePile(count: 5)
        XCTAssertEqual(five.flowerGroups.count, 1)
        XCTAssertEqual(five.flowerGroups.first?.memberIDs.count, 5)
        XCTAssertEqual(five.flowerGroups.first?.visibleMemberIDs.count, 5)
        XCTAssertEqual(five.pinItems.count, 5)

        let four = try solvePile(count: 4)
        XCTAssertTrue(four.flowerGroups.isEmpty)
        XCTAssertEqual(four.pinItems.count, 4)
        try Self.assertNoBodyOverlaps(layout: four, config: config, tolerance: 1.5)
    }

    func testGroupingHysteresisKeepsFlowerBetweenEnterAndExitRadii() throws {
        var config = Self.makeConfig()
        config.groupingThreshold = 1
        let solver = PinCollisionLayoutSolver()
        var time: TimeInterval = 0
        // enterR = 35, exitR = 45.5 at pinSizePx = 100.

        func solveOnce(distance: Float) throws -> PinCollisionLayout {
            time += 1.0 / 60.0
            return solver.solve(projectedPins: [
                                    try Self.makeProjected(id: 1, position: SIMD2(400, 300)),
                                    try Self.makeProjected(id: 2, position: SIMD2(400 + distance, 300))
                                ],
                                geometry: Self.geometry,
                                config: config,
                                time: time)
        }

        XCTAssertTrue(try solveOnce(distance: 41).flowerGroups.isEmpty,
                      "41px > enterR: the pair must not group")
        XCTAssertEqual(try solveOnce(distance: 30).flowerGroups.count, 1,
                       "30px <= enterR: the pair groups into a flower")
        XCTAssertEqual(try solveOnce(distance: 41).flowerGroups.count, 1,
                       "41px <= exitR: the flower holds (hysteresis)")
        XCTAssertTrue(try solveOnce(distance: 60).flowerGroups.isEmpty,
                      "60px > exitR: the flower falls apart")
    }

    func testSelectedPinJoinsFlowerAsVisiblePetal() throws {
        var config = Self.makeConfig()
        config.groupingThreshold = 1
        let solver = PinCollisionLayoutSolver()
        let pins = [
            try Self.makeProjected(id: 5, position: SIMD2(400, 300), isSelected: true),
            try Self.makeProjected(id: 2, position: SIMD2(402, 300)),
            try Self.makeProjected(id: 3, position: SIMD2(404, 300))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        XCTAssertEqual(layout.flowerGroups.count, 1)
        let group = try XCTUnwrap(layout.flowerGroups.first)
        XCTAssertEqual(group.memberIDs, [2, 3, 5])
        // The selected member is guaranteed among visible petals and comes first.
        XCTAssertEqual(group.visibleMemberIDs.first, 5)
        XCTAssertEqual(layout.pinItems.count, 3)
    }

    func testFlowerStaysPutAndNeighborsReactOnlyToPetalTouch() throws {
        var config = Self.makeConfig()
        config.groupingThreshold = 2
        let solver = PinCollisionLayoutSolver()
        // The trio forms a flower with the centroid at (400, 300.67). Neighbor
        // id 8 actually touches the nearest petal; neighbor id 9 only falls
        // inside the ring's invisible circumscribed circle and must not be touched.
        let pins = [
            try Self.makeProjected(id: 1, position: SIMD2(398, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(402, 300)),
            try Self.makeProjected(id: 3, position: SIMD2(400, 302)),
            try Self.makeProjected(id: 8, position: SIMD2(440, 300)),
            try Self.makeProjected(id: 9, position: SIMD2(475, 380))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        XCTAssertEqual(layout.flowerGroups.count, 1)
        let group = try XCTUnwrap(layout.flowerGroups.first)
        XCTAssertEqual(group.memberIDs, [1, 2, 3])
        // The cluster stands on the centroid of its anchors: neighbors do not move it.
        XCTAssertLessThan(simd_length(group.center - SIMD2(400.0, 300.6666)), 0.01)
        // The neighbor touching a petal yields: displaced and turned into a circle.
        let touching = try XCTUnwrap(layout.pinItems.first { $0.pin.id == 8 })
        XCTAssertGreaterThan(simd_length(touching.screenPoint.position - touching.anchorScreenPoint.position), 5.0)
        XCTAssertGreaterThan(touching.morph, 0.5)
        // The neighbor inside the circumscribed circle but away from the petals: an untouched pin.
        let bystander = try XCTUnwrap(layout.pinItems.first { $0.pin.id == 9 })
        XCTAssertEqual(bystander.screenPoint.position, SIMD2(475, 380))
        XCTAssertEqual(bystander.morph, 0.0, accuracy: 0.05)
        XCTAssertEqual(bystander.displayScale, 1.0, accuracy: 0.01)
    }

    func testOverlappingFlowersMergeIntoOne() throws {
        // Two flowers are immovable and cannot yield to each other: ring
        // overlap is resolved by merging into a single flower.
        var config = Self.makeConfig()
        config.groupingThreshold = 2
        let solver = PinCollisionLayoutSolver()
        var pins: [ProjectedPin] = []
        for id in 1...3 {
            pins.append(try Self.makeProjected(id: UInt64(id),
                                                  position: SIMD2(400 + Float(id), 300)))
        }
        for id in 11...13 {
            pins.append(try Self.makeProjected(id: UInt64(id),
                                                  position: SIMD2(460 + Float(id), 300)))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        XCTAssertEqual(layout.flowerGroups.count, 1)
        XCTAssertEqual(layout.flowerGroups.first?.memberIDs.count, 6)
        try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 1.5)
    }

    func testSelectedTouchingFlowerJoinsItAsPetal() throws {
        // The selected pin's anchor is outside the grouping radius, but its
        // immovable body touches the flower ring: the conflict of two rigid
        // bodies is resolved by including the selected one in the flower as the first petal.
        var config = Self.makeConfig()
        config.groupingThreshold = 2
        let solver = PinCollisionLayoutSolver()
        let pins = [
            try Self.makeProjected(id: 1, position: SIMD2(398, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(402, 300)),
            try Self.makeProjected(id: 3, position: SIMD2(400, 302)),
            try Self.makeProjected(id: 9, position: SIMD2(470, 300), isSelected: true)
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        XCTAssertEqual(layout.flowerGroups.count, 1)
        let group = try XCTUnwrap(layout.flowerGroups.first)
        XCTAssertEqual(group.memberIDs, [1, 2, 3, 9])
        XCTAssertEqual(group.visibleMemberIDs.first, 9)
        try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 1.5)
    }

    func testPinAnchoredInsideRingIsAbsorbed() throws {
        // The pin's anchor is inside the flower ring: the spring would pull
        // it into the flower forever, so it is absorbed by the pile.
        var config = Self.makeConfig()
        config.groupingThreshold = 2
        let solver = PinCollisionLayoutSolver()
        let pins = [
            try Self.makeProjected(id: 1, position: SIMD2(398, 300)),
            try Self.makeProjected(id: 2, position: SIMD2(402, 300)),
            try Self.makeProjected(id: 3, position: SIMD2(400, 302)),
            try Self.makeProjected(id: 9, position: SIMD2(400, 320))
        ]
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        XCTAssertEqual(layout.flowerGroups.count, 1)
        XCTAssertEqual(layout.flowerGroups.first?.memberIDs, [1, 2, 3, 9])
    }

    func testHiddenFlowerMembersReappearAfterBreakup() throws {
        var config = Self.makeConfig()
        config.groupingThreshold = 3
        let solver = PinCollisionLayoutSolver()
        var time: TimeInterval = 0
        let piledPins = try (1...9).map { id in
            try Self.makeProjected(id: UInt64(id),
                                   position: SIMD2(400 + Float(id) * 0.5, 300))
        }
        let piled = try Self.solveUntilSettled(solver: solver,
                                               pins: piledPins,
                                               config: config,
                                               time: &time)
        XCTAssertEqual(piled.pinItems.count, PinCollisionMath.maxFlowerPetals)

        // Anchors fly apart: the flower disbands, hidden members return.
        let spreadPins = try (1...9).map { id in
            try Self.makeProjected(id: UInt64(id),
                                   position: SIMD2(Float(id) * 400.0, 300))
        }
        let spread = try Self.solveUntilSettled(solver: solver,
                                                pins: spreadPins,
                                                config: config,
                                                time: &time)
        XCTAssertTrue(spread.flowerGroups.isEmpty)
        XCTAssertEqual(spread.pinItems.count, 9)
    }

    // MARK: - Cluster locality

    func testSprawlingChainSplitsIntoLocalFlowers() throws {
        // A pin chain spanning half the screen is pairwise connected, but a
        // cluster must be local: an overgrown component is cut by the world
        // grid, and each member's anchor stays near its ring (previously the
        // chain collapsed into one flower with cones across the whole screen).
        var config = Self.makeConfig()
        config.groupingThreshold = 3
        let solver = PinCollisionLayoutSolver()
        let pins = try (0..<17).map { step in
            try Self.makeProjected(id: UInt64(step + 1),
                                   position: SIMD2(400.0 + Float(step) * 30.0, 300.0))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        let compactnessLimit = Self.geometry.pinSizePx * PinCollisionMath.flowerCompactnessLimitScale
        XCTAssertGreaterThan(layout.flowerGroups.count, 1, "The oversized group was not split")
        var coveredMembers = 0
        for group in layout.flowerGroups {
            coveredMembers += group.memberIDs.count
            for memberID in group.memberIDs {
                let anchor = SIMD2<Float>(400.0 + Float(memberID - 1) * 30.0, 300.0)
                XCTAssertLessThan(simd_length(anchor - group.center), compactnessLimit,
                                  "The anchor of member \(memberID) is far from its cluster's ring")
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
            let solver = PinCollisionLayoutSolver()
            let pins = try (0..<17).map { step -> ProjectedPin in
                let basePosition = SIMD2(400.0 + Float(step) * 30.0, 300.0)
                return try Self.makeProjected(id: UInt64(step + 1),
                                              position: basePosition + panOffset,
                                              worldPosition: SIMD2(Double(basePosition.x) * 0.001,
                                                                   Double(basePosition.y) * 0.001))
            }
            return try Self.solveUntilSettled(solver: solver,
                                              pins: pins,
                                              config: config)
                .flowerGroups.map(\.memberIDs)
        }

        XCTAssertNoThrow(try {
            let still = try flowerCompositions(panOffset: .zero)
            let panned = try flowerCompositions(panOffset: SIMD2(37.0, 53.0))
            XCTAssertEqual(still, panned, "Panning rebuilt the cluster memberships")
        }())
    }

    func testUnmergeableIntersectingRingsSeparateWithoutOverlap() throws {
        // A dense five and a long chain nearby: their rings intersect, but
        // merging is forbidden by the compactness limit. The rings are pushed
        // apart: the smaller group yields, petals of the two flowers do not overlap.
        var config = Self.makeConfig()
        config.groupingThreshold = 2
        let solver = PinCollisionLayoutSolver()
        var pins: [ProjectedPin] = []
        for id in 1...5 {
            pins.append(try Self.makeProjected(id: UInt64(id),
                                                  position: SIMD2(400.0 + Float(id) * 0.5, 300.0)))
        }
        for step in 0..<9 {
            pins.append(try Self.makeProjected(id: UInt64(20 + step),
                                                  position: SIMD2(450.0, 315.0 + Float(step) * 30.0)))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        XCTAssertEqual(layout.flowerGroups.count, 2, "The clusters merged although the compactness limit forbids it")
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
        let solver = PinCollisionLayoutSolver()
        var generatorState: UInt64 = 7
        func random() -> Float {
            generatorState = generatorState &* 6364136223846793005 &+ 1442695040888963407
            return Float(generatorState >> 40) / Float(UInt64.max >> 40)
        }
        let pins = try (1...800).map { id -> ProjectedPin in
            let angle = random() * 2.0 * .pi
            let radius = 600.0 * random().squareRoot()
            return try Self.makeProjected(id: UInt64(id),
                                          position: SIMD2(900.0 + cos(angle) * radius,
                                                          450.0 + sin(angle) * radius * 0.5))
        }
        let layout = try Self.solveUntilSettled(solver: solver,
                                                pins: pins,
                                                config: config)

        XCTAssertGreaterThan(layout.flowerGroups.count, 3, "A dense field must produce a mosaic of clusters")
        try Self.assertNoBodyOverlaps(layout: layout, config: config, tolerance: 1.5)
    }

    // MARK: - Helpers

    private static func makeConfig() -> ImmersiveMapSettings.PinSettings {
        var config = ImmersiveMapSettings.default.pins
        config.collisionPaddingPx = 0.0
        config.maxOffsetPx = 220.0
        config.collisionIterations = 10
        config.springK = 0.25
        config.smoothing = 0.35
        config.compressedScale = 0.55
        config.groupingThreshold = 10
        return config
    }

    private static func bodyCenter(of item: PinCollisionItem) -> SIMD2<Float> {
        item.screenPoint.position
            + geometry.bodyCenterOffsetPx * (item.displayScale * item.pin.screenSizeScale)
    }

    private static func solveUntilSettled(solver: PinCollisionLayoutSolver,
                                          pins: [ProjectedPin],
                                          config: ImmersiveMapSettings.PinSettings) throws -> PinCollisionLayout {
        var time: TimeInterval = 0
        return try solveUntilSettled(solver: solver,
                                     pins: pins,
                                     config: config,
                                     time: &time)
    }

    private static func solveUntilSettled(solver: PinCollisionLayoutSolver,
                                          pins: [ProjectedPin],
                                          config: ImmersiveMapSettings.PinSettings,
                                          time: inout TimeInterval) throws -> PinCollisionLayout {
        var layout = PinCollisionLayout.empty
        for iteration in 0..<1200 {
            layout = solver.solve(projectedPins: pins,
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
    private static func assertNoBodyOverlaps(layout: PinCollisionLayout,
                                             config: ImmersiveMapSettings.PinSettings,
                                             tolerance: Float = 1.0,
                                             file: StaticString = #filePath,
                                             line: UInt = #line) throws {
        func bodyRadius(of item: PinCollisionItem) -> Float {
            geometry.bodyRadius(morph: item.morph) * item.displayScale * item.pin.screenSizeScale
        }

        for lhsIndex in layout.pinItems.indices {
            for rhsIndex in (lhsIndex + 1)..<layout.pinItems.count {
                let lhs = layout.pinItems[lhsIndex]
                let rhs = layout.pinItems[rhsIndex]
                let distance = simd_length(bodyCenter(of: lhs) - bodyCenter(of: rhs))
                XCTAssertGreaterThanOrEqual(distance,
                                            bodyRadius(of: lhs) + bodyRadius(of: rhs) - tolerance,
                                            "The bodies of pins \(lhs.pin.id) and \(rhs.pin.id) overlap",
                                            file: file,
                                            line: line)
            }
        }
    }

    private static func makeProjected(id: UInt64,
                                      position: SIMD2<Float>,
                                      isSelected: Bool = false,
                                      clusterPolicy: PinClusterPolicy = .none,
                                      visibilityAlpha: Float = 1.0,
                                      worldPosition: SIMD2<Double>? = nil) throws -> ProjectedPin {
        ProjectedPin(pin: try makePin(id: id,
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

    private static func makePin(id: UInt64,
                                   isSelected: Bool,
                                   clusterPolicy: PinClusterPolicy) throws -> ImmersiveMapPin {
        ImmersiveMapPin(id: id,
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
