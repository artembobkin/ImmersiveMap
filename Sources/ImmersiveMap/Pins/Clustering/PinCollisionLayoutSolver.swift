// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  PinCollisionLayoutSolver.swift
//  ImmersiveMap
//

import CoreGraphics
import Foundation
import simd

/// Pin projection onto the screen before collision resolution.
struct ProjectedPin {
    let pin: ImmersiveMapPin
    let squashScale: SIMD2<Float>
    let screenPoint: ScreenPointOutput
    /// World (normalized Mercator) anchor position: a pan-stable basis for
    /// splitting sprawling piles with the world grid.
    let worldPosition: SIMD2<Double>
    let drawOrder: Int

    init(pin: ImmersiveMapPin,
         squashScale: SIMD2<Float>,
         screenPoint: ScreenPointOutput,
         worldPosition: SIMD2<Double>? = nil,
         drawOrder: Int) {
        self.pin = pin
        self.squashScale = squashScale
        self.screenPoint = screenPoint
        // Fallback for synthetic calls (tests): any linear mapping of the
        // screen into "world" is consistent with the grid split.
        self.worldPosition = worldPosition
            ?? SIMD2<Double>(Double(screenPoint.position.x) * 0.001,
                             Double(screenPoint.position.y) * 0.001)
        self.drawOrder = drawOrder
    }
}

/// Placement result for one pin: the displaced screen point, the true anchor
/// (projection of the geo position), and the current shape (pin in place or a
/// displaced circle).
struct PinCollisionItem {
    let pin: ImmersiveMapPin
    let squashScale: SIMD2<Float>
    let screenPoint: ScreenPointOutput
    let anchorScreenPoint: ScreenPointOutput
    let displayScale: Float
    let morph: Float
    /// Flower petal: sits in its ring slot and is not moved by corrections.
    let isFlowerPetal: Bool
    let drawOrder: Int
}

/// Flower-cluster metadata: pile membership and visible petals. The flower is
/// rendered with regular pin items; this structure exists for introspection
/// and tests.
struct PinFlowerGroup {
    let memberIDs: [UInt64]
    let visibleMemberIDs: [UInt64]
    let center: SIMD2<Float>
}

/// Screen-space pin geometry the solver needs: the pin body is offset up
/// from the anchor (the pin's bottom stands on the geo point), so collisions are
/// resolved on body centers, not anchors, otherwise pins of different scales
/// would ride over each other.
struct PinCollisionGeometry {
    /// Full pin size (for grouping thresholds).
    let pinSizePx: Float
    /// Pin body radius at scale 1 (half-width of the rounded square).
    let bodyRadiusPx: Float
    /// Visible circle radius (morph 1) at scale 1: the body's inscribed circle.
    let circleBodyRadiusPx: Float
    /// Shift of the body center from the anchor at scale 1.
    let bodyCenterOffsetPx: SIMD2<Float>

    /// Nominal body radius for the current shape: the pin is wider than the
    /// circle, and computing from the pin radius would leave a visible gap
    /// between circles.
    func bodyRadius(morph: Float) -> Float {
        bodyRadiusPx + (circleBodyRadiusPx - bodyRadiusPx) * simd_clamp(morph, 0.0, 1.0)
    }
}

struct PinCollisionLayout {
    static let empty = PinCollisionLayout(pinItems: [],
                                             flowerGroups: [],
                                             hasActiveAnimations: false)

    let pinItems: [PinCollisionItem]
    let flowerGroups: [PinFlowerGroup]
    let hasActiveAnimations: Bool

    /// Every pin exactly on its coordinate, at full size, in its draw
    /// order: the layout of a map whose pins do not spread apart
    /// (`ImmersiveMapSettings.PinSettings.spreadsApart`). Nothing is
    /// pushed, so nothing moves between frames and no pin has a beam.
    static func anchored(_ projectedPins: [ProjectedPin]) -> PinCollisionLayout {
        let items = projectedPins
            .sorted { $0.drawOrder < $1.drawOrder }
            .map { projected in
                PinCollisionItem(pin: projected.pin,
                                 squashScale: projected.squashScale,
                                 screenPoint: projected.screenPoint,
                                 anchorScreenPoint: projected.screenPoint,
                                 displayScale: 1,
                                 morph: 0,
                                 isFlowerPetal: false,
                                 drawOrder: projected.drawOrder)
            }
        return PinCollisionLayout(pinItems: items, flowerGroups: [], hasActiveAnimations: false)
    }
}

/// Zenly-like pin placement: pins push each other apart as circles in
/// screen space (Gauss-Seidel with a spring to the anchor); only a pin
/// standing exactly on its geo point keeps the pin shape, a displaced pin is
/// a shrunken circle with a cone to the geo point; dense piles are laid out as
/// a "flower" of petals, members that don't fit are hidden. Keeps inter-frame
/// state for smooth, fps-independent transitions.
final class PinCollisionLayoutSolver {

    private struct PinMotionState {
        var offset: SIMD2<Float>
        var scale: Float
        var morph: Float
        var clusterBlend: Float
        var lastClusterKey: UInt64?
    }

    private struct ClusterMotionState {
        var presence: Float
        var memberIDs: [UInt64]
    }

    private struct ClusterSeed {
        let stateKey: UInt64
        /// Member indexes into the frame input, ascending (id order).
        /// Membership is stored as indexes: copying pin arrays with their
        /// image references was a noticeable cost item for the mega-pile.
        let memberIndexes: [Int]
        let memberIDs: [UInt64]
        /// Centroid of the members' screen anchors.
        let anchor: SIMD2<Float>
        /// Bounds of the screen anchors: the compactness limit for merges.
        let boundsMin: SIMD2<Float>
        let boundsMax: SIMD2<Float>
        /// Ring position: the anchor centroid, may be shifted when separating
        /// intersecting unmergeable rings.
        var center: SIMD2<Float>
    }

    private struct SolverNode {
        let anchor: SIMD2<Float>
        var position: SIMD2<Float>
        let radius: Float
        let inverseMass: Float
        let directionKey: UInt64
    }

    private var pinStates: [UInt64: PinMotionState] = [:]
    /// Key is the minimum member id: preserves state across membership changes.
    private var clusterStates: [UInt64: ClusterMotionState] = [:]
    private var previouslyGroupedPinIDs: Set<UInt64> = []
    private var lastTime: TimeInterval?

    func solve(projectedPins: [ProjectedPin],
               geometry: PinCollisionGeometry,
               config: ImmersiveMapSettings.PinSettings,
               time: TimeInterval) -> PinCollisionLayout {
        defer { lastTime = time }
        guard projectedPins.isEmpty == false else {
            pinStates.removeAll(keepingCapacity: true)
            clusterStates.removeAll(keepingCapacity: true)
            previouslyGroupedPinIDs.removeAll(keepingCapacity: true)
            return .empty
        }

        let deltaSeconds = min(max(time - (lastTime ?? time), 0.0),
                               PinCollisionMath.maxFrameDeltaSeconds)
        let smoothingK = PinCollisionMath.smoothingFactor(smoothing: config.smoothing,
                                                             deltaSeconds: deltaSeconds)
        let blendStep = Float(deltaSeconds) / max(PinCollisionMath.clusterCrossfadeSeconds, 0.001)
        let pinSizePx = geometry.pinSizePx
        let compressedScale = min(config.compressedScale, 1.0)
        let petalBodyRadius = geometry.circleBodyRadiusPx * compressedScale

        // The input is almost always already ordered by id; sorting is a safety
        // net for arbitrary calls (a full sort of 30k every frame is noticeable).
        var inputIsSorted = true
        for index in 1..<projectedPins.count
        where projectedPins[index - 1].pin.id >= projectedPins[index].pin.id {
            inputIsSorted = false
            break
        }
        let input = inputIsSorted
            ? projectedPins
            : projectedPins.sorted { $0.pin.id < $1.pin.id }
        var unsettled = false

        // Previous frame's group membership: grouping hysteresis and detection
        // of stationarily hidden members whose state has already been reset.
        let groupedLastFrame = previouslyGroupedPinIDs

        // A cluster must be local: the limit on the spread of one flower's
        // screen anchors cuts chain percolation and merge cascades.
        let compactnessLimit = pinSizePx * PinCollisionMath.flowerCompactnessLimitScale

        // Grouping: legacy event clusters + overflow piles with hysteresis.
        let eventSeeds = eventClusterSeeds(input: input, pinSizePx: pinSizePx, config: config)
        let eventClusteredIDs = Set(eventSeeds.flatMap(\.memberIDs))
        let overflowSeeds = overflowClusterSeeds(input: input,
                                                 excluded: eventClusteredIDs,
                                                 pinSizePx: pinSizePx,
                                                 compactnessLimit: compactnessLimit,
                                                 config: config)

        // Flowers and rigid bodies cannot yield to each other, so conflicts
        // between them are resolved by membership: flowers with intersecting
        // rings merge; a selected pin touching a flower with its body joins
        // it as a petal; a pin whose anchor lies inside the ring is absorbed.
        var clusterSeeds = mergeIntersectingFlowers((eventSeeds + overflowSeeds),
                                                    input: input,
                                                    petalBodyRadius: petalBodyRadius,
                                                    compactnessLimit: compactnessLimit)
        var clusteredFlags = [Bool](repeating: false, count: input.count)
        for seed in clusterSeeds {
            for memberIndex in seed.memberIndexes {
                clusteredFlags[memberIndex] = true
            }
        }
        var standaloneIndexes = input.indices.filter { clusteredFlags[$0] == false }
        absorbPinsIntoFlowers(seeds: &clusterSeeds,
                                 standaloneIndexes: &standaloneIndexes,
                                 input: input,
                                 geometry: geometry,
                                 petalBodyRadius: petalBodyRadius,
                                 config: config)
        clusterSeeds = mergeIntersectingFlowers(clusterSeeds,
                                                input: input,
                                                petalBodyRadius: petalBodyRadius,
                                                compactnessLimit: compactnessLimit)
            .sorted { $0.stateKey < $1.stateKey }

        // Rings of unmergeable neighbors (compactness limit) are separated
        // until they no longer intersect: petals of different flowers don't overlap.
        separateFlowerRings(&clusterSeeds, petalBodyRadius: petalBodyRadius)

        // Next frame's hysteresis keeps the widened radius for all flower
        // members (absorbed and merged ones are part of the pile too).
        var groupedThisFrame = Set<UInt64>(minimumCapacity: input.count)
        for seed in clusterSeeds {
            groupedThisFrame.formUnion(seed.memberIDs)
        }
        previouslyGroupedPinIDs = groupedThisFrame

        let standalonePins = standaloneIndexes.map { input[$0] }

        // Every pile of touching pins has a dominant: it keeps the pin shape
        // and does not move, only the others yield (as circles).
        let dominantIDs = dominantPinIDs(standalonePins: standalonePins,
                                            clusterSeeds: clusterSeeds,
                                            geometry: geometry,
                                            config: config)

        // Two-pass scheme without inter-frame feedback (a node radius driven by
        // the smoothed morph oscillated at the contact boundary): pass A with
        // full-size bodies decides who is displaced; pass B with radii from
        // pass A's morph targets yields the final positions. Both targets are
        // pure continuous functions of the anchors, so size and shape don't jitter.
        var probeNodes = makeNodes(standalonePins: standalonePins,
                                   clusterSeeds: clusterSeeds,
                                   dominantIDs: dominantIDs,
                                   geometry: geometry,
                                   config: config,
                                   nodeShapeForPin: { _, _ in (scale: 1.0, bodyRadius: geometry.bodyRadiusPx) })
        relax(nodes: &probeNodes, config: config)
        var fullBodyMorphs: [Float] = []
        fullBodyMorphs.reserveCapacity(standalonePins.count)
        for index in standalonePins.indices {
            let probeOffset = probeNodes[index].position - probeNodes[index].anchor
            fullBodyMorphs.append(PinCollisionMath.displacedMorph(offsetLength: simd_length(probeOffset)))
        }

        // An intermediate pass with shapes from A1 determines the actual
        // neighbor positions and sizes for the static touch check.
        var shapedProbeNodes = makeNodes(standalonePins: standalonePins,
                                         clusterSeeds: clusterSeeds,
                                         dominantIDs: dominantIDs,
                                         geometry: geometry,
                                         config: config,
                                         nodeShapeForPin: { _, index in
                                             (scale: PinCollisionMath.scaleCap(morph: fullBodyMorphs[index]),
                                              bodyRadius: geometry.bodyRadius(morph: fullBodyMorphs[index]))
                                         })
        relax(nodes: &shapedProbeNodes, config: config)

        // Physical shape rule: a pin becomes a circle only if its full-size
        // body at the anchor actually touches neighbors' already shrunken
        // bodies. A circle neighbor doesn't "press" from the distance of its
        // full radius. Candidates come via the grid: only bodies closer than
        // the sum of maximum radii contribute depth; farther ones yield
        // negative depth and don't affect the maximum.
        var maxStandaloneSizeScale: Float = 0.0
        for projected in standalonePins {
            maxStandaloneSizeScale = max(maxStandaloneSizeScale, projected.pin.screenSizeScale)
        }
        var morphTargets: [Float] = []
        morphTargets.reserveCapacity(standalonePins.count)
        if standalonePins.isEmpty == false {
            var maxProbeRadius: Float = 1.0
            var shapedPositions = [SIMD2<Float>](repeating: .zero, count: shapedProbeNodes.count)
            for index in shapedProbeNodes.indices {
                maxProbeRadius = max(maxProbeRadius, shapedProbeNodes[index].radius)
                shapedPositions[index] = shapedProbeNodes[index].position
            }
            let touchCellSize = geometry.bodyRadiusPx * max(maxStandaloneSizeScale, 1.0) + maxProbeRadius
            let touchGrid = PinScreenHashGrid(positions: shapedPositions, cellSize: touchCellSize)
            var touchCandidates: [Int] = []

            for (index, projected) in standalonePins.enumerated() {
                guard fullBodyMorphs[index] > 0.0 else {
                    morphTargets.append(0.0)
                    continue
                }
                let screenSizeScale = projected.pin.screenSizeScale
                let fullBodyCenter = projected.screenPoint.position
                    + geometry.bodyCenterOffsetPx * (screenSizeScale)
                let fullBodyRadius = geometry.bodyRadiusPx * screenSizeScale
                var maxOverlapDepth: Float = 0.0
                touchGrid.collectCandidates(around: fullBodyCenter, into: &touchCandidates)
                for otherIndex in touchCandidates where otherIndex != index {
                    let otherBodyRadius = shapedProbeNodes[otherIndex].radius - config.collisionPaddingPx
                    let distance = simd_length(fullBodyCenter - shapedProbeNodes[otherIndex].position)
                    maxOverlapDepth = max(maxOverlapDepth, fullBodyRadius + otherBodyRadius - distance)
                }
                let touchMorph = PinCollisionMath.staticTouchMorph(overlapDepth: maxOverlapDepth)
                morphTargets.append(min(fullBodyMorphs[index], touchMorph))
            }
        }

        var nodes = makeNodes(standalonePins: standalonePins,
                              clusterSeeds: clusterSeeds,
                              dominantIDs: dominantIDs,
                              geometry: geometry,
                              config: config,
                              nodeShapeForPin: { _, index in
                                  (scale: PinCollisionMath.scaleCap(morph: morphTargets[index]),
                                   bodyRadius: geometry.bodyRadius(morph: morphTargets[index]))
                              })
        relax(nodes: &nodes, config: config)

        // Circle compression is forced and variable: the base displaced circle
        // is displacedCircleScale, under crowding it compresses per pass B's
        // final distances but not below the compressedScale limit. Neighbors
        // via the grid: only bodies within the sum of radii affect the required scale.
        var targetScales: [Float] = []
        targetScales.reserveCapacity(standalonePins.count)
        if standalonePins.isEmpty == false {
            var maxNodeRadius: Float = 1.0
            var nodePositions = [SIMD2<Float>](repeating: .zero, count: nodes.count)
            for index in nodes.indices {
                maxNodeRadius = max(maxNodeRadius, nodes[index].radius)
                nodePositions[index] = nodes[index].position
            }
            let scaleCellSize = max(geometry.bodyRadiusPx * max(maxStandaloneSizeScale, 1.0), maxNodeRadius)
                * 2.0 + 2.0 * config.collisionPaddingPx
            let scaleGrid = PinScreenHashGrid(positions: nodePositions, cellSize: scaleCellSize)
            var scaleCandidates: [Int] = []

            for (index, projected) in standalonePins.enumerated() {
                // The shape is decided by pass A: a pin only when the full-size
                // pin has room to stand on its geo point. Otherwise in the
                // boundary zone (full bodies push, circles don't) pins would intersect.
                let morphTarget = morphTargets[index]
                let capScale = PinCollisionMath.scaleCap(morph: morphTarget)
                var scale = capScale
                let isRigid = projected.pin.isSelected || dominantIDs.contains(projected.pin.id)
                if isRigid == false, morphTarget > 0.0 {
                    let bodyRadius = geometry.bodyRadius(morph: morphTarget) * projected.pin.screenSizeScale
                    var required: Float = 1.0
                    scaleGrid.collectNeighbors(ofPointAt: index, greaterThan: Int.min, into: &scaleCandidates)
                    for otherIndex in scaleCandidates where otherIndex != index {
                        let distance = simd_length(nodes[index].position - nodes[otherIndex].position)
                        let otherIsPin = otherIndex < standalonePins.count
                        let otherBodyRadius = otherIsPin
                            ? geometry.bodyRadius(morph: morphTargets[otherIndex]) * standalonePins[otherIndex].pin.screenSizeScale
                            : nodes[otherIndex].radius - config.collisionPaddingPx
                        let otherIsRigid = otherIsPin
                            ? (standalonePins[otherIndex].pin.isSelected
                                || dominantIDs.contains(standalonePins[otherIndex].pin.id))
                            : true
                        guard distance < bodyRadius + otherBodyRadius + 2.0 * config.collisionPaddingPx else {
                            continue
                        }
                        required = min(required, PinCollisionMath.requiredScale(distance: distance,
                                                                                   bodyRadius: bodyRadius,
                                                                                   otherBodyRadius: otherBodyRadius,
                                                                                   padding: config.collisionPaddingPx,
                                                                                   otherIsRigid: otherIsRigid))
                    }
                    let lowerLimit = min(compressedScale, capScale)
                    scale = max(min(required, capScale), lowerLimit)
                } else if projected.pin.isSelected {
                    scale = 1.0
                }
                targetScales.append(scale)
            }
        }

        var pinItems: [PinCollisionItem] = []
        pinItems.reserveCapacity(input.count)
        var flowerGroups: [PinFlowerGroup] = []
        flowerGroups.reserveCapacity(clusterSeeds.count)
        var clusterCentersByKey: [UInt64: SIMD2<Float>] = [:]
        var seenClusterKeys = Set<UInt64>()
        var seenPinIDs = Set<UInt64>()

        // Cluster membership by input index: petal selection and advancing
        // hidden members without a full scan of the mega membership.
        var seedIndexByInputIndex = [Int](repeating: -1, count: input.count)
        for (seedIndex, seed) in clusterSeeds.enumerated() {
            for memberIndex in seed.memberIndexes {
                seedIndexByInputIndex[memberIndex] = seedIndex
            }
        }
        var selectedIndexesBySeed = [[Int]](repeating: [], count: clusterSeeds.count)
        for index in input.indices where input[index].pin.isSelected {
            let seedIndex = seedIndexByInputIndex[index]
            if seedIndex >= 0 {
                selectedIndexesBySeed[seedIndex].append(index)
            }
        }

        // Live flowers: the ring at the pile center (the anchor centroid,
        // possibly separated from neighboring rings), petal layout.
        for (seedIndex, seed) in clusterSeeds.enumerated() {
            seenClusterKeys.insert(seed.stateKey)
            var state = clusterStates[seed.stateKey] ?? ClusterMotionState(presence: 1.0,
                                                                           memberIDs: seed.memberIDs)
            let presenceActive = advanceBlend(&state.presence, target: 1.0, step: blendStep)
            state.memberIDs = seed.memberIDs
            unsettled = unsettled || presenceActive
            clusterStates[seed.stateKey] = state

            let flowerCenter = seed.center
            clusterCentersByKey[seed.stateKey] = flowerCenter

            let petalCount = min(seed.memberIndexes.count, PinCollisionMath.maxFlowerPetals)
            let ringRadius = PinCollisionMath.flowerRingRadius(petalBodyRadius: petalBodyRadius,
                                                                  petalCount: petalCount)
            // Selected members are guaranteed among the visible petals and go
            // first; the fill-up takes the lowest ids (membership is sorted, so
            // the fill-up walks only a prefix, not the whole mega membership).
            var visibleMemberIndexes: [Int] = []
            visibleMemberIndexes.reserveCapacity(petalCount)
            for selectedIndex in selectedIndexesBySeed[seedIndex] {
                visibleMemberIndexes.append(selectedIndex)
                if visibleMemberIndexes.count == petalCount { break }
            }
            if visibleMemberIndexes.count < petalCount {
                for memberIndex in seed.memberIndexes where input[memberIndex].pin.isSelected == false {
                    visibleMemberIndexes.append(memberIndex)
                    if visibleMemberIndexes.count == petalCount { break }
                }
            }
            flowerGroups.append(PinFlowerGroup(memberIDs: seed.memberIDs,
                                                  visibleMemberIDs: visibleMemberIndexes.map { input[$0].pin.id },
                                                  center: flowerCenter))

            for (slotIndex, memberIndex) in visibleMemberIndexes.enumerated() {
                let member = input[memberIndex]
                let slotCenter = flowerCenter
                    + PinCollisionMath.flowerPetalOffset(index: slotIndex,
                                                            petalCount: petalCount,
                                                            ringRadius: ringRadius)
                emitPetal(member: member,
                          slotCenter: slotCenter,
                          stateKey: seed.stateKey,
                          wasGroupedLastFrame: groupedLastFrame.contains(member.pin.id),
                          geometry: geometry,
                          compressedScale: compressedScale,
                          smoothingK: smoothingK,
                          blendStep: blendStep,
                          unsettled: &unsettled,
                          seenPinIDs: &seenPinIDs,
                          pinItems: &pinItems)
            }
        }

        // Hidden flower members: stationary ones have no state and need no
        // work, so only live inter-frame states (a handful) are advanced, not
        // the whole mega membership. Petals are already accounted for and
        // skipped via seenPinIDs.
        if pinStates.isEmpty == false, clusterSeeds.isEmpty == false {
            for id in pinStates.keys.sorted() where seenPinIDs.contains(id) == false {
                guard let inputIndex = Self.inputIndex(ofID: id, in: input) else { continue }
                let seedIndex = seedIndexByInputIndex[inputIndex]
                guard seedIndex >= 0 else { continue }
                emitHiddenMember(member: input[inputIndex],
                                 flowerCenter: clusterSeeds[seedIndex].center,
                                 stateKey: clusterSeeds[seedIndex].stateKey,
                                 geometry: geometry,
                                 compressedScale: compressedScale,
                                 smoothingK: smoothingK,
                                 blendStep: blendStep,
                                 unsettled: &unsettled,
                                 seenPinIDs: &seenPinIDs,
                                 pinItems: &pinItems)
            }
        }

        // Dissolved flowers: the center is still needed by members flying out
        // while presence fades. The member -> key map lets stationarily hidden
        // ones (no state) start their fly-out from the dissolved pile's center.
        var dissolvedKeyByMemberID: [UInt64: UInt64] = [:]
        for key in clusterStates.keys.sorted() where seenClusterKeys.contains(key) == false {
            guard var state = clusterStates[key] else { continue }
            var anchor = SIMD2<Float>.zero
            var memberCount = 0
            for memberID in state.memberIDs {
                guard let member = Self.projectedPin(withID: memberID, in: input) else { continue }
                anchor += member.screenPoint.position
                memberCount += 1
            }
            guard memberCount > 0 else {
                clusterStates.removeValue(forKey: key)
                continue
            }
            let presenceActive = advanceBlend(&state.presence, target: 0.0, step: blendStep)
            guard state.presence > 0.0 else {
                clusterStates.removeValue(forKey: key)
                continue
            }
            unsettled = unsettled || presenceActive
            clusterStates[key] = state

            clusterCentersByKey[key] = anchor / Float(memberCount)
            for memberID in state.memberIDs where dissolvedKeyByMemberID[memberID] == nil {
                dissolvedKeyByMemberID[memberID] = key
            }
        }

        // Standalone pins: smoothing of offset/scale/morph, fly-out from
        // the flower.
        for (index, projected) in standalonePins.enumerated() {
            let id = projected.pin.id
            seenPinIDs.insert(id)
            let targetOffset = nodes[index].position - nodes[index].anchor
            // A pin keeps the pin shape only when the full-size body has
            // room on the geo point (pass A's morph target).
            let targetMorph = morphTargets[index]
            var state: PinMotionState
            if let existing = pinStates[id] {
                state = existing
            } else if groupedLastFrame.contains(id),
                      let dissolvedKey = dissolvedKeyByMemberID[id] {
                // A stationarily hidden member of a dissolved pile (state
                // reset): reappears by flying out of the fading flower center.
                state = PinMotionState(offset: targetOffset,
                                          scale: targetScales[index],
                                          morph: targetMorph,
                                          clusterBlend: 1.0,
                                          lastClusterKey: dissolvedKey)
            } else {
                state = PinMotionState(offset: targetOffset,
                                          scale: targetScales[index],
                                          morph: targetMorph,
                                          clusterBlend: 0.0,
                                          lastClusterKey: nil)
            }
            let offsetActive = smoothToward(&state.offset,
                                            target: targetOffset,
                                            factor: smoothingK,
                                            epsilon: PinCollisionMath.offsetSnapEpsilonPx)
            let scaleActive = smoothToward(&state.scale,
                                           target: targetScales[index],
                                           factor: smoothingK,
                                           epsilon: PinCollisionMath.scaleSnapEpsilon)
            let morphActive = smoothToward(&state.morph,
                                           target: targetMorph,
                                           factor: smoothingK,
                                           epsilon: PinCollisionMath.scaleSnapEpsilon)
            let blendActive = advanceBlend(&state.clusterBlend, target: 0.0, step: blendStep)
            unsettled = unsettled || offsetActive || scaleActive || morphActive || blendActive

            // Anchor correction: the center of the actual (compressed) body
            // stays at the point solved by pass B for a body of scale scaleCap(morph A).
            let nodeScale = PinCollisionMath.scaleCap(morph: morphTargets[index])
            let bodyCenterLift = geometry.bodyCenterOffsetPx * projected.pin.screenSizeScale
                * (nodeScale - state.scale)
            var position = projected.screenPoint.position + state.offset
                + bodyCenterLift
            var alphaFactor: Float = 1.0
            if state.clusterBlend > 0.0 {
                if let clusterKey = state.lastClusterKey,
                   let center = clusterCentersByKey[clusterKey] {
                    let ease = PinCollisionMath.smoothstep(edge0: 0.0, edge1: 1.0, x: state.clusterBlend)
                    position += (center - position) * ease
                    alphaFactor = 1.0 - state.clusterBlend
                } else {
                    state.clusterBlend = 0.0
                }
            }
            if state.clusterBlend <= 0.0 {
                state.lastClusterKey = nil
            }
            pinStates[id] = state

            var screenPoint = projected.screenPoint
            screenPoint.position = position
            screenPoint.visibilityAlpha *= alphaFactor
            pinItems.append(PinCollisionItem(pin: projected.pin,
                                                         squashScale: projected.squashScale,
                                                         screenPoint: screenPoint,
                                                         anchorScreenPoint: projected.screenPoint,
                                                         displayScale: state.scale,
                                                         morph: state.morph,
                                                         isFlowerPetal: false,
                                                         drawOrder: projected.drawOrder))
        }

        for id in Array(pinStates.keys) where seenPinIDs.contains(id) == false {
            pinStates.removeValue(forKey: id)
        }

        // Hard per-frame guarantee: smoothing lags behind the targets, and in
        // transitional frames bodies may overlap. The final pass resolves
        // displayed-body overlaps directly; in the converged state it is a
        // no-op and does not touch inter-frame state.
        resolveDisplayedOverlaps(pinItems: &pinItems,
                                 geometry: geometry,
                                 compressedScale: compressedScale)

        pinItems.sort {
            if $0.drawOrder != $1.drawOrder {
                return $0.drawOrder < $1.drawOrder
            }
            return $0.pin.id < $1.pin.id
        }

        return PinCollisionLayout(pinItems: pinItems,
                                     flowerGroups: flowerGroups,
                                     hasActiveAnimations: unsettled)
    }

    /// Micro-correction of displayed positions: removes brief overlaps of the
    /// actual bodies during animations. Works on top of the smoothed state and
    /// does not write into it, so it does not affect convergence.
    private func resolveDisplayedOverlaps(pinItems: inout [PinCollisionItem],
                                          geometry: PinCollisionGeometry,
                                          compressedScale: Float) {
        guard pinItems.count > 1 else { return }

        var centers: [SIMD2<Float>] = []
        var radii: [Float] = []
        var inverseMasses: [Float] = []
        centers.reserveCapacity(pinItems.count)
        radii.reserveCapacity(pinItems.count)
        inverseMasses.reserveCapacity(pinItems.count)
        for item in pinItems {
            let bodyScale = item.displayScale * item.pin.screenSizeScale
            centers.append(item.screenPoint.position
                + geometry.bodyCenterOffsetPx * (bodyScale))
            // Fading members of the cluster crossfade fly through the others:
            // a zero radius excludes them from the correction.
            let isFadingThrough = item.screenPoint.visibilityAlpha
                < item.anchorScreenPoint.visibilityAlpha * 0.99
            radii.append(isFadingThrough ? 0.0 : geometry.bodyRadius(morph: item.morph) * bodyScale)
            // Pins (morph 0) and flower petals stay put; only free circles yield.
            let isImmovable = item.pin.isSelected || item.isFlowerPetal
            inverseMasses.append(isImmovable ? 0.0 : item.morph)
        }

        // Pairs are found via a grid over solid (nonzero-radius) bodies.
        // Fading-vs-fading pairs are impossible (minDistance 0); fading vs
        // solid are checked with point queries, otherwise the collapse
        // transient of a large pile (thousands of fading bodies at one point)
        // would again produce a quadratic scan.
        var solidIndices: [Int] = []
        var fadingIndices: [Int] = []
        var maxSolidRadius: Float = 1.0
        for index in radii.indices {
            if radii[index] > 0.0 {
                solidIndices.append(index)
                maxSolidRadius = max(maxSolidRadius, radii[index])
            } else {
                fadingIndices.append(index)
            }
        }
        let cellSize = 2.0 * maxSolidRadius
        var solidPositions = [SIMD2<Float>](repeating: .zero, count: solidIndices.count)
        var candidates: [Int] = []

        func resolvePair(_ lhsIndex: Int, _ rhsIndex: Int) {
            var lhsInverseMass = inverseMasses[lhsIndex]
            var rhsInverseMass = inverseMasses[rhsIndex]
            let bothPetals = pinItems[lhsIndex].isFlowerPetal && pinItems[rhsIndex].isFlowerPetal
            if bothPetals {
                // Petals are immovable only toward standalone circles. A pair of
                // petals from different flowers is two "immovable" bodies: in a
                // super-dense mosaic of rings the center separation cannot pull
                // them apart, and without mutual yielding the overlap would freeze.
                lhsInverseMass = pinItems[lhsIndex].pin.isSelected ? 0.0 : 1.0
                rhsInverseMass = pinItems[rhsIndex].pin.isSelected ? 0.0 : 1.0
            }
            let inverseMassSum = lhsInverseMass + rhsInverseMass
            guard inverseMassSum > 0 else { return }
            let minDistance = radii[lhsIndex] + radii[rhsIndex]
            let delta = centers[rhsIndex] - centers[lhsIndex]
            let distanceSquared = simd_length_squared(delta)
            guard distanceSquared < minDistance * minDistance else { return }
            let distance = distanceSquared.squareRoot()
            let overlap = minDistance - distance
            // Slots of one ring touch exactly: float micro-noise must not push
            // a flower's own petals apart.
            if bothPetals, overlap <= 1.0 { return }
            let direction = distance > 1e-4
                ? delta / distance
                : PinCollisionMath.stableUnitDirection(idA: pinItems[lhsIndex].pin.id,
                                                          idB: pinItems[rhsIndex].pin.id)
            centers[lhsIndex] -= direction * overlap * (lhsInverseMass / inverseMassSum)
            centers[rhsIndex] += direction * overlap * (rhsInverseMass / inverseMassSum)
        }

        // Candidate pairs are collected once: over the correction iterations
        // bodies move within a radius, which the radius margin covers.
        for (localIndex, itemIndex) in solidIndices.enumerated() {
            solidPositions[localIndex] = centers[itemIndex]
        }
        let grid = PinScreenHashGrid(positions: solidPositions, cellSize: cellSize)
        var pairs: [(Int, Int)] = []
        for fadingIndex in fadingIndices {
            grid.collectCandidates(around: centers[fadingIndex], into: &candidates)
            for localIndex in candidates {
                let solidIndex = solidIndices[localIndex]
                let reach = radii[fadingIndex] + radii[solidIndex] + maxSolidRadius
                if simd_length_squared(centers[fadingIndex] - centers[solidIndex]) < reach * reach {
                    pairs.append((min(fadingIndex, solidIndex), max(fadingIndex, solidIndex)))
                }
            }
        }
        for (localIndex, itemIndex) in solidIndices.enumerated() {
            grid.collectNeighbors(ofPointAt: localIndex,
                                  greaterThan: localIndex,
                                  into: &candidates)
            for otherLocalIndex in candidates {
                let otherIndex = solidIndices[otherLocalIndex]
                let reach = radii[itemIndex] + radii[otherIndex] + maxSolidRadius
                if simd_length_squared(centers[itemIndex] - centers[otherIndex]) < reach * reach {
                    pairs.append((itemIndex, otherIndex))
                }
            }
        }

        // A dense mosaic of rings converges slowly: a pair separated on the
        // first iteration creates an overlap with the next neighbor.
        for _ in 0..<20 {
            for pair in pairs {
                resolvePair(pair.0, pair.1)
            }
        }

        // Mosaic desync: the solver compressed circles against ring slots while
        // the actual petals were shifted by the correction. A circle squeezed
        // between bodies immovable to it is compressed further per the actual
        // distances (within the compression limit), after which the positions
        // are re-settled.
        var scaleAdjusted = false
        for pair in pairs {
            let residualMinDistance = radii[pair.0] + radii[pair.1]
            let delta = centers[pair.1] - centers[pair.0]
            let distanceSquared = simd_length_squared(delta)
            guard residualMinDistance > 0.5,
                  distanceSquared < (residualMinDistance - 0.5) * (residualMinDistance - 0.5) else {
                continue
            }
            let distance = distanceSquared.squareRoot()
            for (candidateIndex, otherIndex) in [(pair.0, pair.1), (pair.1, pair.0)] {
                let item = pinItems[candidateIndex]
                guard item.isFlowerPetal == false,
                      item.pin.isSelected == false,
                      item.morph > 0.5,
                      radii[candidateIndex] > 0 else {
                    continue
                }
                let unitBodyRadius = geometry.bodyRadius(morph: item.morph) * item.pin.screenSizeScale
                guard unitBodyRadius > 0 else { continue }
                let required = (distance - radii[otherIndex]) / unitBodyRadius
                let lowerLimit = min(compressedScale, item.displayScale)
                let newScale = max(min(required, item.displayScale), lowerLimit)
                guard newScale < item.displayScale - 0.005 else { continue }
                pinItems[candidateIndex] = PinCollisionItem(pin: item.pin,
                                                                        squashScale: item.squashScale,
                                                                        screenPoint: item.screenPoint,
                                                                        anchorScreenPoint: item.anchorScreenPoint,
                                                                        displayScale: newScale,
                                                                        morph: item.morph,
                                                                        isFlowerPetal: item.isFlowerPetal,
                                                                        drawOrder: item.drawOrder)
                radii[candidateIndex] = unitBodyRadius * newScale
                scaleAdjusted = true
            }
        }
        if scaleAdjusted {
            for _ in 0..<8 {
                for pair in pairs {
                    resolvePair(pair.0, pair.1)
                }
            }
        }

        for index in pinItems.indices {
            let item = pinItems[index]
            let bodyScale = item.displayScale * item.pin.screenSizeScale
            let correctedPosition = centers[index]
                - geometry.bodyCenterOffsetPx * (bodyScale)
            guard simd_length(correctedPosition - item.screenPoint.position) > 0.01 else { continue }
            var screenPoint = item.screenPoint
            screenPoint.position = correctedPosition
            pinItems[index] = PinCollisionItem(pin: item.pin,
                                                           squashScale: item.squashScale,
                                                           screenPoint: screenPoint,
                                                           anchorScreenPoint: item.anchorScreenPoint,
                                                           displayScale: item.displayScale,
                                                           morph: item.morph,
                                                           isFlowerPetal: item.isFlowerPetal,
                                                           drawOrder: item.drawOrder)
        }
    }

    // MARK: - Flower petals

    /// A petal is a regular pin whose offset target is set by a slot on the
    /// flower ring: the flight into the slot and back uses the same smoothing
    /// as the push-apart.
    private func emitPetal(member: ProjectedPin,
                           slotCenter: SIMD2<Float>,
                           stateKey: UInt64,
                           wasGroupedLastFrame: Bool,
                           geometry: PinCollisionGeometry,
                           compressedScale: Float,
                           smoothingK: Float,
                           blendStep: Float,
                           unsettled: inout Bool,
                           seenPinIDs: inout Set<UInt64>,
                           pinItems: inout [PinCollisionItem]) {
        let id = member.pin.id
        seenPinIDs.insert(id)
        let screenSizeScale = member.pin.screenSizeScale
        // The target offset puts the petal's body center exactly into the slot.
        let targetOffset = slotCenter - member.screenPoint.position
            - geometry.bodyCenterOffsetPx * (screenSizeScale * compressedScale)
        // A stationarily hidden member has no state (it was reset); promotion
        // to a petal starts with blend 1, a fade-in appearance, just like the
        // earlier "live" hidden state.
        var state = pinStates[id] ?? PinMotionState(offset: targetOffset,
                                                          scale: compressedScale,
                                                          morph: 1.0,
                                                          clusterBlend: wasGroupedLastFrame ? 1.0 : 0.0,
                                                          lastClusterKey: stateKey)
        state.lastClusterKey = stateKey
        let offsetActive = smoothToward(&state.offset,
                                        target: targetOffset,
                                        factor: smoothingK,
                                        epsilon: PinCollisionMath.offsetSnapEpsilonPx)
        let scaleActive = smoothToward(&state.scale,
                                       target: compressedScale,
                                       factor: smoothingK,
                                       epsilon: PinCollisionMath.scaleSnapEpsilon)
        let morphActive = smoothToward(&state.morph,
                                       target: 1.0,
                                       factor: smoothingK,
                                       epsilon: PinCollisionMath.scaleSnapEpsilon)
        let blendActive = advanceBlend(&state.clusterBlend, target: 0.0, step: blendStep)
        unsettled = unsettled || offsetActive || scaleActive || morphActive || blendActive
        pinStates[id] = state

        var screenPoint = member.screenPoint
        screenPoint.position = member.screenPoint.position + state.offset
        screenPoint.visibilityAlpha *= 1.0 - state.clusterBlend
        pinItems.append(PinCollisionItem(pin: member.pin,
                                                     squashScale: member.squashScale,
                                                     screenPoint: screenPoint,
                                                     anchorScreenPoint: member.screenPoint,
                                                     displayScale: state.scale,
                                                     morph: state.morph,
                                                     isFlowerPetal: true,
                                                     drawOrder: member.drawOrder))
    }

    /// A member that did not fit into the flower: fades out while converging on the flower center.
    private func emitHiddenMember(member: ProjectedPin,
                                  flowerCenter: SIMD2<Float>,
                                  stateKey: UInt64,
                                  geometry: PinCollisionGeometry,
                                  compressedScale: Float,
                                  smoothingK: Float,
                                  blendStep: Float,
                                  unsettled: inout Bool,
                                  seenPinIDs: inout Set<UInt64>,
                                  pinItems: inout [PinCollisionItem]) {
        let id = member.pin.id
        // A stationarily hidden member: no state, nothing to create, nothing
        // to animate, not drawn. The early exit makes a calm world zoom with
        // tens of thousands of hidden members nearly free.
        guard var state = pinStates[id] else { return }
        seenPinIDs.insert(id)
        state.lastClusterKey = stateKey
        let blendActive = advanceBlend(&state.clusterBlend, target: 1.0, step: blendStep)
        let offsetActive = smoothToward(&state.offset,
                                        target: .zero,
                                        factor: smoothingK,
                                        epsilon: PinCollisionMath.offsetSnapEpsilonPx)
        let scaleActive = smoothToward(&state.scale,
                                       target: compressedScale,
                                       factor: smoothingK,
                                       epsilon: PinCollisionMath.scaleSnapEpsilon)
        let morphActive = smoothToward(&state.morph,
                                       target: 1.0,
                                       factor: smoothingK,
                                       epsilon: PinCollisionMath.scaleSnapEpsilon)
        unsettled = unsettled || blendActive || offsetActive || scaleActive || morphActive

        // A fully faded member has settled: the state is reset; a reappearance
        // as a petal or standalone will be indicated by the previous frame's
        // group membership (groupedLastFrame).
        if state.clusterBlend >= 0.999,
           blendActive == false, offsetActive == false,
           scaleActive == false, morphActive == false {
            pinStates.removeValue(forKey: id)
            return
        }
        pinStates[id] = state

        guard state.clusterBlend < 0.999 else { return }
        let ease = PinCollisionMath.smoothstep(edge0: 0.0, edge1: 1.0, x: state.clusterBlend)
        let base = member.screenPoint.position + state.offset
        var screenPoint = member.screenPoint
        screenPoint.position = base + (flowerCenter - base) * ease
        screenPoint.visibilityAlpha *= 1.0 - state.clusterBlend
        pinItems.append(PinCollisionItem(pin: member.pin,
                                                     squashScale: member.squashScale,
                                                     screenPoint: screenPoint,
                                                     anchorScreenPoint: member.screenPoint,
                                                     displayScale: state.scale,
                                                     morph: state.morph,
                                                     isFlowerPetal: false,
                                                     drawOrder: member.drawOrder))
    }

    // MARK: - Grouping

    private func eventClusterSeeds(input: [ProjectedPin],
                                   pinSizePx: Float,
                                   config: ImmersiveMapSettings.PinSettings) -> [ClusterSeed] {
        let threshold = max(1.0, pinSizePx + config.collisionPaddingPx * 2.0)
        let thresholdSquared = threshold * threshold
        let candidateIndexes = input.indices.filter { input[$0].pin.clusterPolicy == .event }
        return connectedGroups(of: candidateIndexes,
                               in: input,
                               maxJoinDistance: threshold) { lhs, rhs in
            simd_length_squared(lhs.screenPoint.position - rhs.screenPoint.position) <= thresholdSquared
        }
        .filter { $0.count > 1 }
        .map { makeSeed(memberIndexes: $0, input: input) }
    }

    private func overflowClusterSeeds(input: [ProjectedPin],
                                      excluded: Set<UInt64>,
                                      pinSizePx: Float,
                                      compactnessLimit: Float,
                                      config: ImmersiveMapSettings.PinSettings) -> [ClusterSeed] {
        let enterRadius = pinSizePx * PinCollisionMath.groupingRadiusScale
        let exitRadius = enterRadius * PinCollisionMath.groupingHysteresisRatio
        let candidateIndexes = excluded.isEmpty
            ? Array(input.indices)
            : input.indices.filter { excluded.contains(input[$0].pin.id) == false }
        let previouslyGrouped = previouslyGroupedPinIDs
        let components = connectedGroups(of: candidateIndexes,
                                         in: input,
                                         maxJoinDistance: exitRadius) { lhs, rhs in
            // The widened (hysteresis) radius holds an already formed group
            // together but does not pull in neighbors passing by.
            let widened = previouslyGrouped.contains(lhs.pin.id) && previouslyGrouped.contains(rhs.pin.id)
            let radius = widened ? exitRadius : enterRadius
            return simd_length_squared(lhs.screenPoint.position - rhs.screenPoint.position) <= radius * radius
        }
        // Chain percolation: on a dense field a connected component stretches
        // across the whole screen, and a ring would receive members hundreds of
        // px away. Overgrown components are cut by the world grid into local piles.
        return splitSprawlingComponents(components,
                                        input: input,
                                        compactnessLimit: compactnessLimit,
                                        groupingThreshold: config.groupingThreshold)
            // A flower forms once the pile reaches the threshold (and at least a pair).
            .filter { $0.count > 1 && $0.count >= config.groupingThreshold }
            .map { makeSeed(memberIndexes: $0, input: input) }
    }

    /// Splits components whose screen-anchor spread exceeds the limit by a
    /// world grid: cell boundaries are anchored to the world (stable under pan
    /// and rotation), the step is a power of two (changes in zoom octaves, and
    /// membership jumps are smoothed by the cluster crossfade). The pixel/world
    /// scale is derived from the points themselves.
    private func splitSprawlingComponents(_ components: [[Int]],
                                          input: [ProjectedPin],
                                          compactnessLimit: Float,
                                          groupingThreshold: Int) -> [[Int]] {
        var result: [[Int]] = []
        result.reserveCapacity(components.count)
        for component in components {
            guard component.count > 1 else {
                result.append(component)
                continue
            }
            var screenMin = input[component[0]].screenPoint.position
            var screenMax = screenMin
            for index in component.dropFirst() {
                let position = input[index].screenPoint.position
                screenMin = simd_min(screenMin, position)
                screenMax = simd_max(screenMax, position)
            }
            let screenDiagonal = simd_length(screenMax - screenMin)
            guard screenDiagonal > compactnessLimit else {
                result.append(component)
                continue
            }

            var worldMin = input[component[0]].worldPosition
            var worldMax = worldMin
            for index in component.dropFirst() {
                let world = input[index].worldPosition
                worldMin = simd_min(worldMin, world)
                worldMax = simd_max(worldMax, world)
            }
            let worldDiagonal = simd_length(worldMax - worldMin)
            guard worldDiagonal > 0 else {
                result.append(component)
                continue
            }

            let pixelsPerWorldUnit = Double(screenDiagonal) / worldDiagonal
            let rawStep = Double(compactnessLimit) / pixelsPerWorldUnit
            let step = pow(2.0, rawStep.isFinite ? floor(log2(rawStep)) : 0.0)
            var cellsBuckets: [SIMD2<Int64>: [Int]] = [:]
            for index in component {
                let world = input[index].worldPosition
                let cell = SIMD2<Int64>(Int64((world.x / step).rounded(.down)),
                                        Int64((world.y / step).rounded(.down)))
                cellsBuckets[cell, default: []].append(index)
            }
            // Dictionary order is nondeterministic: subgroups are sorted by
            // their smallest member.
            var subgroups = cellsBuckets.values.sorted { ($0.first ?? 0) < ($1.first ?? 0) }

            // Undersized subgroups merge into the nearest full subgroup of the
            // same pile: a free circle inside a solid mosaic of rings physically
            // has no room, its body would freeze in an overlap.
            let seedThreshold = max(groupingThreshold, 2)
            var fullSubgroups: [(subgroupIndex: Int, centroid: SIMD2<Float>)] = []
            for (subgroupIndex, subgroup) in subgroups.enumerated() where subgroup.count >= seedThreshold {
                var centroid = SIMD2<Float>.zero
                for memberIndex in subgroup {
                    centroid += input[memberIndex].screenPoint.position
                }
                fullSubgroups.append((subgroupIndex, centroid / Float(subgroup.count)))
            }
            if fullSubgroups.isEmpty == false {
                for (subgroupIndex, subgroup) in subgroups.enumerated()
                where subgroup.count < seedThreshold {
                    var centroid = SIMD2<Float>.zero
                    for memberIndex in subgroup {
                        centroid += input[memberIndex].screenPoint.position
                    }
                    centroid /= Float(subgroup.count)
                    var nearestIndex = fullSubgroups[0].subgroupIndex
                    var nearestDistance = Float.greatestFiniteMagnitude
                    for candidate in fullSubgroups {
                        let distance = simd_length_squared(candidate.centroid - centroid)
                        if distance < nearestDistance {
                            nearestDistance = distance
                            nearestIndex = candidate.subgroupIndex
                        }
                    }
                    subgroups[nearestIndex].append(contentsOf: subgroup)
                    subgroups[subgroupIndex] = []
                }
                for subgroupIndex in subgroups.indices where subgroups[subgroupIndex].isEmpty == false {
                    subgroups[subgroupIndex].sort()
                }
                subgroups.removeAll(where: \.isEmpty)
            }
            result.append(contentsOf: subgroups)
        }
        return result
    }

    /// Dense grid cell: this many candidates in one cell of the join radius is
    /// guaranteed to be a crowd, pairwise checks inside it are unnecessary
    /// (members would chain together through the 3x3 neighborhood anyway).
    private static let denseGroupingCellPopulation = 16
    /// How many members of a dense cell a neighboring sparse pin is checked
    /// against exactly before concluding there is no link.
    private static let denseGroupingProbeLimit = 64

    /// Connected components by a pairwise predicate via a spatial grid:
    /// cellSize = the maximum join distance, so all potential pairs lie within
    /// the 3x3 neighborhood. Dense cells (crowds) are united wholesale without
    /// pairwise scanning, otherwise a 30k-pin pile on one screen would cost
    /// hundreds of millions of checks. Candidates arrive in ascending order
    /// (id order), group membership is deterministic; returns groups of input indexes.
    private func connectedGroups(of candidateIndexes: [Int],
                                 in input: [ProjectedPin],
                                 maxJoinDistance: Float,
                                 position: (ProjectedPin) -> SIMD2<Float> = { $0.screenPoint.position },
                                 joinable: (ProjectedPin, ProjectedPin) -> Bool) -> [[Int]] {
        guard candidateIndexes.count > 1 else {
            return []
        }

        let positions = candidateIndexes.map { position(input[$0]) }
        let grid = PinScreenHashGrid(positions: positions, cellSize: maxJoinDistance)
        var disjointSet = PinDisjointSet(count: candidateIndexes.count)
        var neighbors: [Int] = []

        // Dense cells are handled at cell level: a crowd is united wholesale,
        // neighboring crowds merge (their flower rings would have intersected
        // and merged by membership anyway).
        let denseSlots = grid.cellSlots(withPopulationAtLeast: Self.denseGroupingCellPopulation)
        var isDenseSlot = [Bool](repeating: false, count: grid.cellCount)
        for slot in denseSlots {
            isDenseSlot[slot] = true
        }
        for slot in denseSlots {
            let cell = grid.entries(inCellSlot: slot)
            guard let first = cell.first else { continue }
            for other in cell.dropFirst() {
                disjointSet.union(first, other)
            }
            grid.forEachNeighborSlot(of: slot) { neighborSlot in
                guard neighborSlot > slot, isDenseSlot[neighborSlot] else { return }
                if let neighborFirst = grid.entries(inCellSlot: neighborSlot).first {
                    disjointSet.union(first, neighborFirst)
                }
            }
        }

        // The pointwise pass covers only points of sparse cells.
        for lhsIndex in candidateIndexes.indices
        where isDenseSlot[grid.cellSlot(ofPointAt: lhsIndex)] == false {
            grid.forEachNeighborCell(ofPointAt: lhsIndex) { cell, _ in
                if cell.count >= Self.denseGroupingCellPopulation {
                    // A sparse pin against a crowd: an exact check over a
                    // bounded sample (ids within the cell are randomly
                    // distributed across the screen, so the sample covers it evenly).
                    var probesLeft = Self.denseGroupingProbeLimit
                    for rhsIndex in cell {
                        if joinable(input[candidateIndexes[lhsIndex]], input[candidateIndexes[rhsIndex]]) {
                            disjointSet.union(lhsIndex, rhsIndex)
                            break
                        }
                        probesLeft -= 1
                        if probesLeft <= 0 { break }
                    }
                    return
                }
                // Sparse cells: exact pair scan (i, j > i).
                for rhsIndex in cell where rhsIndex > lhsIndex {
                    neighbors.append(rhsIndex)
                }
            }

            if neighbors.isEmpty == false {
                neighbors.sort()
                for rhsIndex in neighbors where joinable(input[candidateIndexes[lhsIndex]], input[candidateIndexes[rhsIndex]]) {
                    disjointSet.union(lhsIndex, rhsIndex)
                }
                neighbors.removeAll(keepingCapacity: true)
            }
        }

        // Components are extracted without hashing: the root is the minimum
        // index, the first encounter of a root sets the group order, so the
        // groups come out already sorted by smallest id.
        var slotOfRoot = [Int](repeating: -1, count: candidateIndexes.count)
        var groupedIndexes: [[Int]] = []
        for index in candidateIndexes.indices {
            let root = disjointSet.find(index)
            var slot = slotOfRoot[root]
            if slot == -1 {
                slot = groupedIndexes.count
                slotOfRoot[root] = slot
                groupedIndexes.append([])
            }
            groupedIndexes[slot].append(index)
        }

        return groupedIndexes.map { indexes in indexes.map { candidateIndexes[$0] } }
    }

    /// Outer flower radius: the slot ring plus the petal body.
    private func flowerOuterRadius(memberCount: Int, petalBodyRadius: Float) -> Float {
        let petalCount = min(memberCount, PinCollisionMath.maxFlowerPetals)
        return PinCollisionMath.flowerRingRadius(petalBodyRadius: petalBodyRadius,
                                                    petalCount: petalCount) + petalBodyRadius
    }

    /// Flowers are immovable and cannot yield to each other: piles with
    /// intersecting rings merge into one flower. Merging runs in rounds via
    /// union-find (a merge grows the ring and can catch new neighbors, so
    /// rounds repeat to a fixed point). A merge whose anchor spread would
    /// exceed the compactness limit is forbidden: a merge cascade used to smear
    /// a cluster across half the screen and pull in pins far from the ring.
    private func mergeIntersectingFlowers(_ seeds: [ClusterSeed],
                                          input: [ProjectedPin],
                                          petalBodyRadius: Float,
                                          compactnessLimit: Float) -> [ClusterSeed] {
        guard seeds.count > 1 else { return seeds }

        let limitSquared = compactnessLimit * compactnessLimit
        var merged = seeds.sorted { $0.stateKey < $1.stateKey }
        while merged.count > 1 {
            var disjointSet = PinDisjointSet(count: merged.count)
            var didMerge = false
            for lhsIndex in merged.indices {
                let lhsRadius = flowerOuterRadius(memberCount: merged[lhsIndex].memberIDs.count,
                                                  petalBodyRadius: petalBodyRadius)
                for rhsIndex in (lhsIndex + 1)..<merged.count {
                    let minDistance = lhsRadius
                        + flowerOuterRadius(memberCount: merged[rhsIndex].memberIDs.count,
                                            petalBodyRadius: petalBodyRadius)
                    guard simd_length_squared(merged[lhsIndex].center - merged[rhsIndex].center)
                            < minDistance * minDistance else {
                        continue
                    }
                    let unionMin = simd_min(merged[lhsIndex].boundsMin, merged[rhsIndex].boundsMin)
                    let unionMax = simd_max(merged[lhsIndex].boundsMax, merged[rhsIndex].boundsMax)
                    guard simd_length_squared(unionMax - unionMin) <= limitSquared else {
                        continue
                    }
                    disjointSet.union(lhsIndex, rhsIndex)
                    didMerge = true
                }
            }
            guard didMerge else { break }

            var componentIndexes: [Int: [Int]] = [:]
            for index in merged.indices {
                componentIndexes[disjointSet.find(index), default: []].append(index)
            }
            merged = componentIndexes.keys.sorted().map { root in
                let indexes = componentIndexes[root] ?? []
                guard indexes.count > 1 else { return merged[indexes[0]] }
                var memberIndexes = merged[indexes[0]].memberIndexes
                for otherIndex in indexes.dropFirst() {
                    memberIndexes = Self.mergeSortedIndexes(memberIndexes,
                                                            merged[otherIndex].memberIndexes)
                }
                return makeSeed(memberIndexes: memberIndexes, input: input)
            }
            .sorted { $0.stateKey < $1.stateKey }
        }
        return merged
    }

    /// Intersecting flower rings that are forbidden to merge by the compactness
    /// limit are separated: the flower with the smaller membership moves (on a
    /// tie, the one with the larger key). The non-intersection guarantee is
    /// preserved, and standalone pins still do not move flowers.
    private func separateFlowerRings(_ seeds: inout [ClusterSeed],
                                     petalBodyRadius: Float) {
        guard seeds.count > 1 else { return }

        for _ in 0..<8 {
            var moved = false
            for lhsIndex in seeds.indices {
                let lhsRadius = flowerOuterRadius(memberCount: seeds[lhsIndex].memberIDs.count,
                                                  petalBodyRadius: petalBodyRadius)
                for rhsIndex in (lhsIndex + 1)..<seeds.count {
                    let minDistance = lhsRadius
                        + flowerOuterRadius(memberCount: seeds[rhsIndex].memberIDs.count,
                                            petalBodyRadius: petalBodyRadius)
                    let delta = seeds[rhsIndex].center - seeds[lhsIndex].center
                    let distanceSquared = simd_length_squared(delta)
                    guard distanceSquared < minDistance * minDistance else { continue }
                    let distance = distanceSquared.squareRoot()
                    let direction = distance > 1e-4
                        ? delta / distance
                        : PinCollisionMath.stableUnitDirection(idA: seeds[lhsIndex].stateKey,
                                                                  idB: seeds[rhsIndex].stateKey)
                    let overlap = minDistance - distance
                    let lhsYields = seeds[lhsIndex].memberIDs.count < seeds[rhsIndex].memberIDs.count
                        || (seeds[lhsIndex].memberIDs.count == seeds[rhsIndex].memberIDs.count
                            && seeds[lhsIndex].stateKey > seeds[rhsIndex].stateKey)
                    if lhsYields {
                        seeds[lhsIndex].center -= direction * overlap
                    } else {
                        seeds[rhsIndex].center += direction * overlap
                    }
                    moved = true
                }
            }
            guard moved else { break }
        }
    }

    /// Merges two sorted index lists in linear time.
    private static func mergeSortedIndexes(_ lhs: [Int], _ rhs: [Int]) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(lhs.count + rhs.count)
        var lhsIndex = 0
        var rhsIndex = 0
        while lhsIndex < lhs.count, rhsIndex < rhs.count {
            if lhs[lhsIndex] <= rhs[rhsIndex] {
                result.append(lhs[lhsIndex])
                lhsIndex += 1
            } else {
                result.append(rhs[rhsIndex])
                rhsIndex += 1
            }
        }
        result.append(contentsOf: lhs[lhsIndex...])
        result.append(contentsOf: rhs[rhsIndex...])
        return result
    }

    /// Binary search for a pin index by id in the sorted frame input.
    private static func inputIndex(ofID id: UInt64,
                                   in input: [ProjectedPin]) -> Int? {
        var low = 0
        var high = input.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let candidate = input[middle].pin.id
            if candidate == id {
                return middle
            } else if candidate < id {
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return nil
    }

    /// Binary search for a pin by id in the sorted frame input.
    private static func projectedPin(withID id: UInt64,
                                        in input: [ProjectedPin]) -> ProjectedPin? {
        var low = 0
        var high = input.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let candidate = input[middle].pin.id
            if candidate == id {
                return input[middle]
            } else if candidate < id {
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return nil
    }

    /// Pin absorption by a flower: a selected pin joins as a petal on
    /// body touch (it is immovable and cannot yield to the flower); a regular
    /// pin is absorbed when its anchor body ends up inside the ring, where
    /// the spring would forever pull it into the flower.
    private func absorbPinsIntoFlowers(seeds: inout [ClusterSeed],
                                          standaloneIndexes: inout [Int],
                                          input: [ProjectedPin],
                                          geometry: PinCollisionGeometry,
                                          petalBodyRadius: Float,
                                          config: ImmersiveMapSettings.PinSettings) {
        guard seeds.isEmpty == false, standaloneIndexes.isEmpty == false else { return }

        var absorbedIndexes = Set<Int>()
        for pinIndex in standaloneIndexes {
            let projected = input[pinIndex]
            let screenSizeScale = projected.pin.screenSizeScale
            let bodyCenter = projected.screenPoint.position
                + geometry.bodyCenterOffsetPx * (screenSizeScale)
            // The smallest possible body: if even a maximally compressed circle
            // touches petals of two or more flowers, the pin is wedged in a
            // pocket of the mosaic with nowhere to retreat, and the overlap
            // would freeze forever.
            let minimalBodyRadius = petalBodyRadius * screenSizeScale
            var touchedSeedCount = 0
            var nearestTouchedSeedIndex = -1
            var nearestTouchedDistance = Float.greatestFiniteMagnitude

            for seedIndex in seeds.indices {
                let seed = seeds[seedIndex]
                let ringRadius = flowerOuterRadius(memberCount: seed.memberIDs.count,
                                                   petalBodyRadius: petalBodyRadius) - petalBodyRadius
                let threshold: Float
                if projected.pin.isSelected {
                    threshold = ringRadius + petalBodyRadius
                        + geometry.bodyRadiusPx * screenSizeScale + config.collisionPaddingPx
                } else {
                    threshold = ringRadius
                }
                if simd_length_squared(bodyCenter - seed.center) < threshold * threshold {
                    seeds[seedIndex] = makeSeed(memberIndexes: Self.mergeSortedIndexes(seed.memberIndexes,
                                                                                       [pinIndex]),
                                                input: input)
                    absorbedIndexes.insert(pinIndex)
                    break
                }
                guard projected.pin.isSelected == false else { continue }
                let petalCount = min(seed.memberIDs.count, PinCollisionMath.maxFlowerPetals)
                let slotRing = PinCollisionMath.flowerRingRadius(petalBodyRadius: petalBodyRadius,
                                                                    petalCount: petalCount)
                let touchDistance = minimalBodyRadius + petalBodyRadius
                for petalIndex in 0..<petalCount {
                    let slotCenter = seed.center
                        + PinCollisionMath.flowerPetalOffset(index: petalIndex,
                                                                petalCount: petalCount,
                                                                ringRadius: slotRing)
                    let distance = simd_length(bodyCenter - slotCenter)
                    if distance < touchDistance {
                        touchedSeedCount += 1
                        if distance < nearestTouchedDistance {
                            nearestTouchedDistance = distance
                            nearestTouchedSeedIndex = seedIndex
                        }
                        break
                    }
                }
            }

            if absorbedIndexes.contains(pinIndex) == false,
               touchedSeedCount >= 2,
               nearestTouchedSeedIndex >= 0 {
                let seed = seeds[nearestTouchedSeedIndex]
                seeds[nearestTouchedSeedIndex] = makeSeed(memberIndexes: Self.mergeSortedIndexes(seed.memberIndexes,
                                                                                                 [pinIndex]),
                                                          input: input)
                absorbedIndexes.insert(pinIndex)
            }
        }
        standaloneIndexes.removeAll { absorbedIndexes.contains($0) }
    }

    private func makeSeed(memberIndexes: [Int], input: [ProjectedPin]) -> ClusterSeed {
        var memberIDs: [UInt64] = []
        memberIDs.reserveCapacity(memberIndexes.count)
        var anchor = SIMD2<Float>.zero
        var boundsMin = input[memberIndexes[0]].screenPoint.position
        var boundsMax = boundsMin
        for index in memberIndexes {
            let position = input[index].screenPoint.position
            memberIDs.append(input[index].pin.id)
            anchor += position
            boundsMin = simd_min(boundsMin, position)
            boundsMax = simd_max(boundsMax, position)
        }
        let centroid = anchor / Float(memberIndexes.count)
        return ClusterSeed(stateKey: memberIDs[0],
                           memberIndexes: memberIndexes,
                           memberIDs: memberIDs,
                           anchor: centroid,
                           boundsMin: boundsMin,
                           boundsMax: boundsMax,
                           center: centroid)
    }

    // MARK: - Relaxation

    /// Solver nodes: standalone pins + live flowers. A pin node is
    /// centered on the body center (anchor + vertical shift by the current
    /// scale) with the radius of its actual size: circles pack tightly, pins
    /// keep full distances. A flower node covers the whole petal ring.
    /// Relaxation starts from undisplaced positions: the target is then a pure
    /// function of the input, memoryless; otherwise under-resolved clusters
    /// accumulate rotational drift (the "carousel") frame after frame.
    /// Deterministic start jitter breaks degenerate configurations.
    private func makeNodes(standalonePins: [ProjectedPin],
                           clusterSeeds: [ClusterSeed],
                           dominantIDs: Set<UInt64>,
                           geometry: PinCollisionGeometry,
                           config: ImmersiveMapSettings.PinSettings,
                           nodeShapeForPin: (ProjectedPin, Int) -> (scale: Float, bodyRadius: Float)) -> [SolverNode] {
        let compressedScale = min(config.compressedScale, 1.0)
        let petalBodyRadius = geometry.circleBodyRadiusPx * compressedScale
        let jitterAmplitude = geometry.bodyRadiusPx * PinCollisionMath.startJitterScale
        func startJitter(for key: UInt64) -> SIMD2<Float> {
            PinCollisionMath.stableUnitDirection(idA: key,
                                                    idB: PinCollisionMath.startJitterSalt) * jitterAmplitude
        }

        var nodes: [SolverNode] = []
        nodes.reserveCapacity(standalonePins.count + clusterSeeds.count)
        for (index, projected) in standalonePins.enumerated() {
            let shape = nodeShapeForPin(projected, index)
            let screenSizeScale = projected.pin.screenSizeScale
            let bodyCenter = projected.screenPoint.position
                + geometry.bodyCenterOffsetPx * (shape.scale * screenSizeScale)
            let radius = shape.bodyRadius * shape.scale * screenSizeScale + config.collisionPaddingPx
            let isRigid = projected.pin.isSelected || dominantIDs.contains(projected.pin.id)
            nodes.append(SolverNode(anchor: bodyCenter,
                                    position: bodyCenter + startJitter(for: projected.pin.id),
                                    radius: max(1.0, radius),
                                    inverseMass: isRigid ? 0.0 : 1.0,
                                    directionKey: projected.pin.id))
        }
        // A flower is immovable and represented by its actual petals: neighbors
        // interact with the visible circles, not with the invisible circumscribed
        // circle of the ring (otherwise a pin would "feel" the cluster from a distance).
        for seed in clusterSeeds {
            let petalCount = min(seed.memberIDs.count, PinCollisionMath.maxFlowerPetals)
            let ringRadius = PinCollisionMath.flowerRingRadius(petalBodyRadius: petalBodyRadius,
                                                                  petalCount: petalCount)
            for petalIndex in 0..<petalCount {
                let slotCenter = seed.center
                    + PinCollisionMath.flowerPetalOffset(index: petalIndex,
                                                            petalCount: petalCount,
                                                            ringRadius: ringRadius)
                nodes.append(SolverNode(anchor: slotCenter,
                                        position: slotCenter,
                                        radius: petalBodyRadius + config.collisionPaddingPx,
                                        inverseMass: 0.0,
                                        directionKey: seed.stateKey &+ UInt64(petalIndex)))
            }
        }
        return nodes
    }

    /// Pile dominants: in each connected component of touching full-size
    /// bodies, the best-ranked pin (selected, then drawPriority, then lower
    /// id) does not move and keeps the pin shape. A pin whose anchor body
    /// intersects a flower cannot be a dominant: the flower is immovable, and
    /// two immovable bodies would freeze the overlap.
    private func dominantPinIDs(standalonePins: [ProjectedPin],
                                   clusterSeeds: [ClusterSeed],
                                   geometry: PinCollisionGeometry,
                                   config: ImmersiveMapSettings.PinSettings) -> Set<UInt64> {
        guard standalonePins.isEmpty == false else {
            return []
        }

        func bodyCenter(_ projected: ProjectedPin) -> SIMD2<Float> {
            projected.screenPoint.position
                + geometry.bodyCenterOffsetPx * (projected.pin.screenSizeScale)
        }
        func bodyRadius(_ projected: ProjectedPin) -> Float {
            geometry.bodyRadiusPx * projected.pin.screenSizeScale + config.collisionPaddingPx
        }

        var dominants = Set<UInt64>(standalonePins.map(\.pin.id))

        var maxBodyReach: Float = 1.0
        for projected in standalonePins {
            maxBodyReach = max(maxBodyReach, bodyRadius(projected))
        }
        let groups = connectedGroups(of: Array(standalonePins.indices),
                                     in: standalonePins,
                                     maxJoinDistance: 2.0 * maxBodyReach,
                                     position: bodyCenter) { lhs, rhs in
            let minDistance = bodyRadius(lhs) + bodyRadius(rhs)
            return simd_length_squared(bodyCenter(lhs) - bodyCenter(rhs)) < minDistance * minDistance
        }
        for group in groups where group.count > 1 {
            guard group.count == 2 else {
                // Three or more pins packed tightly are all shown as circles:
                // the dominant pin with a daisy around it is kept only for a pair.
                for memberIndex in group {
                    dominants.remove(standalonePins[memberIndex].pin.id)
                }
                continue
            }
            let ranked = group.min { lhsIndex, rhsIndex in
                let lhs = standalonePins[lhsIndex]
                let rhs = standalonePins[rhsIndex]
                if lhs.pin.isSelected != rhs.pin.isSelected {
                    return lhs.pin.isSelected
                }
                if lhs.pin.drawPriority != rhs.pin.drawPriority {
                    return lhs.pin.drawPriority > rhs.pin.drawPriority
                }
                return lhs.pin.id < rhs.pin.id
            }
            for memberIndex in group where memberIndex != ranked {
                dominants.remove(standalonePins[memberIndex].pin.id)
            }
        }

        guard clusterSeeds.isEmpty == false else {
            return dominants
        }
        let compressedScale = min(config.compressedScale, 1.0)
        let petalBodyRadius = geometry.circleBodyRadiusPx * compressedScale
        // Petal slots of all flowers are gathered into one grid: proximity to a
        // flower is checked with a point query rather than scanning every pile.
        var petalSlotCenters: [SIMD2<Float>] = []
        for seed in clusterSeeds {
            let petalCount = min(seed.memberIDs.count, PinCollisionMath.maxFlowerPetals)
            let ringRadius = PinCollisionMath.flowerRingRadius(petalBodyRadius: petalBodyRadius,
                                                                  petalCount: petalCount)
            for petalIndex in 0..<petalCount {
                petalSlotCenters.append(seed.center
                    + PinCollisionMath.flowerPetalOffset(index: petalIndex,
                                                            petalCount: petalCount,
                                                            ringRadius: ringRadius))
            }
        }
        let petalGrid = PinScreenHashGrid(positions: petalSlotCenters,
                                             cellSize: maxBodyReach + petalBodyRadius + config.collisionPaddingPx)
        var petalCandidates: [Int] = []
        for projected in standalonePins where projected.pin.isSelected == false {
            let minDistance = bodyRadius(projected) + petalBodyRadius + config.collisionPaddingPx
            let center = bodyCenter(projected)
            petalGrid.collectCandidates(around: center, into: &petalCandidates)
            for petalIndex in petalCandidates
            where simd_length_squared(center - petalSlotCenters[petalIndex]) < minDistance * minDistance {
                dominants.remove(projected.pin.id)
                break
            }
        }
        return dominants
    }

    /// Positional relaxation: a spring toward the anchor, then pairwise overlap
    /// resolution (immediate application, Gauss-Seidel). The displacement limit
    /// is applied once to the final target: clamping inside iterations makes the
    /// target discontinuous under incompatible constraints (a crowd larger than
    /// maxOffsetPx allows), and the smoothing never converges.
    private func relax(nodes: inout [SolverNode], config: ImmersiveMapSettings.PinSettings) {
        let maxOffset = max(0.0, config.maxOffsetPx)
        defer {
            for index in nodes.indices {
                let offset = nodes[index].position - nodes[index].anchor
                let length = simd_length(offset)
                if length > maxOffset {
                    nodes[index].position = nodes[index].anchor + offset * (maxOffset / max(length, 1e-6))
                } else if length < PinCollisionMath.restSnapRadiusPx {
                    nodes[index].position = nodes[index].anchor
                }
            }
        }

        guard nodes.count > 1 else {
            for index in nodes.indices {
                nodes[index].position = nodes[index].anchor
            }
            return
        }

        let springK = simd_clamp(config.springK, 0.0, 1.0)
        // Candidate pairs are collected once from the start positions (anchors
        // plus jitter): the cellSize with a 1.5x margin also covers pairs that
        // converge during iterations. A rare missed pair is resolved by
        // resolveDisplayedOverlaps and the target recompute next frame.
        var maxRadius: Float = 1.0
        for node in nodes {
            maxRadius = max(maxRadius, node.radius)
        }
        var positions = [SIMD2<Float>](repeating: .zero, count: nodes.count)
        for index in nodes.indices {
            positions[index] = nodes[index].position
        }
        let grid = PinScreenHashGrid(positions: positions, cellSize: 3.0 * maxRadius)
        var pairStarts = [Int](repeating: 0, count: nodes.count + 1)
        var pairNeighbors: [Int32] = []
        var neighbors: [Int] = []
        for index in nodes.indices {
            grid.collectNeighbors(ofPointAt: index, greaterThan: index, into: &neighbors)
            for neighbor in neighbors {
                // A pair stays a candidate if it can touch after closing in by
                // the maxRadius budget; the rest of the 3x3 neighborhood is noise.
                let reach = nodes[index].radius + nodes[neighbor].radius + maxRadius
                if simd_length_squared(positions[index] - positions[neighbor]) < reach * reach {
                    pairNeighbors.append(Int32(neighbor))
                }
            }
            pairStarts[index + 1] = pairNeighbors.count
        }

        for _ in 0..<max(1, config.collisionIterations) {
            for index in nodes.indices {
                if nodes[index].inverseMass > 0 {
                    nodes[index].position += (nodes[index].anchor - nodes[index].position) * springK
                } else {
                    nodes[index].position = nodes[index].anchor
                }
            }
            for lhsIndex in nodes.indices {
                for pairIndex in pairStarts[lhsIndex]..<pairStarts[lhsIndex + 1] {
                    let rhsIndex = Int(pairNeighbors[pairIndex])
                    let lhs = nodes[lhsIndex]
                    let rhs = nodes[rhsIndex]
                    let inverseMassSum = lhs.inverseMass + rhs.inverseMass
                    guard inverseMassSum > 0 else { continue }
                    let minDistance = lhs.radius + rhs.radius
                    let delta = rhs.position - lhs.position
                    let distanceSquared = simd_length_squared(delta)
                    guard distanceSquared < minDistance * minDistance else { continue }
                    let distance = distanceSquared.squareRoot()
                    let direction = distance > 1e-4
                        ? delta / distance
                        : PinCollisionMath.stableUnitDirection(idA: lhs.directionKey,
                                                                  idB: rhs.directionKey)
                    let overlap = minDistance - distance
                    nodes[lhsIndex].position -= direction * overlap * (lhs.inverseMass / inverseMassSum)
                    nodes[rhsIndex].position += direction * overlap * (rhs.inverseMass / inverseMassSum)
                }
            }
        }
    }

    // MARK: - Smoothing

    /// Moves a value toward the target by a fraction of the way; returns true
    /// while the animation hasn't converged (after snapping to the target it
    /// returns false).
    private func smoothToward(_ value: inout Float, target: Float, factor: Float, epsilon: Float) -> Bool {
        let delta = target - value
        if abs(delta) <= epsilon {
            value = target
            return false
        }
        value += delta * factor
        return true
    }

    private func smoothToward(_ value: inout SIMD2<Float>, target: SIMD2<Float>, factor: Float, epsilon: Float) -> Bool {
        let delta = target - value
        if simd_length(delta) <= epsilon {
            value = target
            return false
        }
        value += delta * factor
        return true
    }

    /// Linear crossfade step toward the target; true until it arrives.
    private func advanceBlend(_ value: inout Float, target: Float, step: Float) -> Bool {
        let delta = target - value
        if abs(delta) <= 0.001 {
            value = target
            return false
        }
        value += delta > 0 ? min(step, delta) : max(-step, delta)
        return true
    }
}

