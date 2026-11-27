// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

/// The depth and stencil states of the tile passes, every one built around
/// the tile-priority stencil (`TileSourceStencilPriority`): the tests of
/// the ground of either surface, and the surface mask the standing
/// geometry raises. The prepass that writes the priority keeps its own
/// states (`PlacementStencilSharedResources`).
///
/// Every state here tests `equal` to the source's zoom, the planner's
/// mark, and none writes the priority.
struct TilePriorityDepthStates: SharedGPUResources {
    /// The sphere's opaque ground: the scene depth written.
    let sphereOpaqueOwner: MTLDepthStencilState
    /// The sphere's ribbon cores: the rank depth written under a strict
    /// test (`sphereRibbonOwnerDescriptor`).
    let sphereRibbonOwner: MTLDepthStencilState
    /// The non-owning test for the translucent fills, the ribbons, the
    /// flat road edge lines and the bridge overlay of either surface.
    let tileStencilTest: MTLDepthStencilState
    /// The flat ground's opaque pass: the ground depth written, so a pixel
    /// is shaded once by its topmost opaque layer, under the tile-priority
    /// test.
    let groundOwner: MTLDepthStencilState
    /// The flat road buckets: the rank depth tested and written
    /// (`RoadRankDepth`), under the tile-priority test.
    let roadRank: MTLDepthStencilState
    /// The world-pass buildings: the scene depth (lessEqual, written, for
    /// their own walls and roofs) and the surface mask bit raised, with no
    /// priority test (`extrudedSurfaceMaskDescriptor`).
    let extrudedSurfaceMask: MTLDepthStencilState

    static func make(_ build: SharedGPUResourceBuild) -> TilePriorityDepthStates {
        let device = build.device
        return TilePriorityDepthStates(
            sphereOpaqueOwner: device.makeDepthStencilState(descriptor: sphereOpaqueOwnerDescriptor())!,
            sphereRibbonOwner: device.makeDepthStencilState(descriptor: sphereRibbonOwnerDescriptor())!,
            tileStencilTest: device.makeDepthStencilState(descriptor: tileStencilTestDescriptor())!,
            groundOwner: device.makeDepthStencilState(descriptor: groundOwnerDescriptor())!,
            roadRank: device.makeDepthStencilState(descriptor: roadRankDescriptor())!,
            extrudedSurfaceMask: device.makeDepthStencilState(descriptor: extrudedSurfaceMaskDescriptor())!)
    }

    // MARK: - Stencils

    /// The tile-priority stencil (TileSourceStencilPriority): the stencil
    /// holds the planner's decision, written by the placement prepass, and
    /// every tile pass tests `equal` to its source's zoom and writes
    /// nothing: a source paints the ground it was given and no other.
    /// `opaque` is the pass that lays a source's ground: it reads the
    /// priority bits alone, under the surface mask bit the buildings and
    /// the models raise, which no tile pass clears. Every other pass reads
    /// the mask bit too: a pixel a building or a model stands on carries
    /// it, which puts the value past any reference, so the ribbons, the
    /// roads and the translucent fills never paint over them, whatever
    /// the depth says over a relief, where a road biased off the ground
    /// would.
    static func tilePriorityStencil(opaque: Bool) -> MTLStencilDescriptor {
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .equal
        stencil.stencilFailureOperation = .keep
        stencil.depthFailureOperation = .keep
        stencil.depthStencilPassOperation = .keep
        stencil.readMask = opaque
            ? TileSourceStencilPriority.priorityMask
            : TileSourceStencilPriority.priorityMask | TileSourceStencilPriority.surfaceMaskBit
        stencil.writeMask = 0
        return stencil
    }

    /// The surface mask (TileSourceStencilPriority.surfaceMaskBit): a
    /// standing surface raises the bit wherever it passes both tests, and
    /// nothing else in the stencil changes.
    static func surfaceMaskWriteStencil(compare: MTLCompareFunction) -> MTLStencilDescriptor {
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = compare
        stencil.stencilFailureOperation = .keep
        stencil.depthFailureOperation = .keep
        stencil.depthStencilPassOperation = .replace
        stencil.readMask = TileSourceStencilPriority.priorityMask
        stencil.writeMask = TileSourceStencilPriority.surfaceMaskBit
        return stencil
    }

    // MARK: - Descriptors

    /// The sphere's opaque ground pass: the layer-rank depth (lessEqual,
    /// written) under the tile-priority test.
    private static func sphereOpaqueOwnerDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = CommonDepthStates.sceneDescriptor()
        descriptor.frontFaceStencil = tilePriorityStencil(opaque: true)
        descriptor.backFaceStencil = tilePriorityStencil(opaque: true)
        return descriptor
    }

    /// The sphere's ribbon cores (TilePipeline.SphereRibbonPhase.core):
    /// the rank depth written under a strict test, drawn highest rank
    /// first, so a pixel several strokes cover blends once, by the highest
    /// of them, and a second piece of the same stroke, at the same rank,
    /// is rejected where the first already painted. Under the tile-priority
    /// test with the surface mask, as every non-owning pass.
    private static func sphereRibbonOwnerDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .less
        descriptor.isDepthWriteEnabled = true
        descriptor.frontFaceStencil = tilePriorityStencil(opaque: false)
        descriptor.backFaceStencil = tilePriorityStencil(opaque: false)
        return descriptor
    }

    /// The flat ground's opaque pass: the ground depth test (against the
    /// buildings), WRITING the rank band so a pixel is shaded once by its
    /// topmost opaque layer, under the tile-priority test: a source
    /// paints the ground it was given and no other, whatever the depth
    /// says there, so the sources never meet by depth. The depth test is
    /// lessEqual for a source's own layers, which stack at the band's
    /// steps, and a vector tile over a raster of the same source (its
    /// lines) lies nearer by half a step (TileRaster.metal).
    private static func groundOwnerDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = CommonDepthStates.groundDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = true
        descriptor.frontFaceStencil = tilePriorityStencil(opaque: true)
        descriptor.backFaceStencil = tilePriorityStencil(opaque: true)
        return descriptor
    }

    /// The flat road buckets: the ground depth test against the ranks
    /// (`RoadRankDepth`), WRITING the rank, on the road's source's own
    /// ground (the tile-priority test). A fragment passes only where it is
    /// nearer than what is there, so an opaque road is shaded once per
    /// pixel by its highest rank, and a road that blends lands once per
    /// pixel of a rank, an equal rank failing.
    private static func roadRankDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = CommonDepthStates.groundDescriptor()
        descriptor.isDepthWriteEnabled = true
        descriptor.frontFaceStencil = tilePriorityStencil(opaque: false)
        descriptor.backFaceStencil = tilePriorityStencil(opaque: false)
        return descriptor
    }

    /// The non-owning tile passes of either surface (translucent fills,
    /// ribbons, the flat road edge lines and the bridge overlay): the
    /// ground depth test plus the tile-priority test, no writes.
    private static func tileStencilTestDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = CommonDepthStates.groundDescriptor()
        descriptor.frontFaceStencil = tilePriorityStencil(opaque: false)
        descriptor.backFaceStencil = tilePriorityStencil(opaque: false)
        return descriptor
    }

    /// The world-pass buildings: scene depth for their own occlusion and
    /// nothing else to test. The building coverage is a partition of the
    /// ground (`BuildingCoveragePlanner`), so no two tiles draw a building
    /// over the same ground and the tile-priority test is not needed. A
    /// wall rises into the pixels of the ground behind it, where that test
    /// would compare it against the wrong tile anyway. The surface mask bit
    /// is still raised where a building lands, for the horizon.
    private static func extrudedSurfaceMaskDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = CommonDepthStates.sceneDescriptor()
        descriptor.frontFaceStencil = surfaceMaskWriteStencil(compare: .always)
        descriptor.backFaceStencil = surfaceMaskWriteStencil(compare: .always)
        return descriptor
    }
}
