// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  FrameContextSharedState.swift
//  ImmersiveMap
//

import Metal

struct BaseLabelState {
    nonisolated(unsafe) static let empty = BaseLabelState(labelInputsCount: 0,
                                      labelRuntimeMetaBuffer: nil,
                                      screenPositionsBuffer: nil,
                                      baseLabelsDrawBatches: [],
                                      hasActiveFadeAnimations: false,
                                      hasActiveVisibilityCycle: false)

    var labelInputsCount: Int
    var labelRuntimeMetaBuffer: MTLBuffer?
    var screenPositionsBuffer: MTLBuffer?
    var baseLabelsDrawBatches: [BaseLabelDrawBatch]
    var hasActiveFadeAnimations: Bool
    var hasActiveVisibilityCycle: Bool
}

/// Debug frame of one base label in screen pixels: the collision AABB and the
/// current visibility (labels hidden by collision/horizon still participate in
/// the frame and must show up in the overlay).
struct BaseLabelDebugBox {
    let center: SIMD2<Float>
    let halfSize: SIMD2<Float>
    let isVisible: Bool
}

/// Snapshot of label frames for the debug overlay. Populated only when the
/// HUD toggle is on, otherwise empty and free. Road frames go in a separate
/// list (one frame per glyph): they take part in the same collision solver
/// but are drawn in their own color to stand apart from the base ones.
struct BaseLabelDebugBoxesState {
    nonisolated(unsafe) static let empty = BaseLabelDebugBoxesState(boxes: [], roadBoxes: [])

    let boxes: [BaseLabelDebugBox]
    let roadBoxes: [BaseLabelDebugBox]
}

struct RoadLabelState {
    nonisolated(unsafe) static let empty = RoadLabelState(instanceCount: 0,
                                      glyphCount: 0,
                                      activeRoadLabelTiles: [],
                                      runtimeMetaBuffer: nil,
                                      drawLabels: [],
                                      hasActiveFadeAnimations: false)

    var instanceCount: Int
    var glyphCount: Int
    var activeRoadLabelTiles: [VisibleTile]
    var runtimeMetaBuffer: MTLBuffer?
    var drawLabels: [DrawRoadLabels]
    var hasActiveFadeAnimations: Bool
}

struct AvatarState {
    static let empty = AvatarState(hasActiveAnimations: false,
                                   selectionSnapshot: .empty)

    var hasActiveAnimations: Bool
    var selectionSnapshot: AvatarSelectionSnapshot
}

/// One model tile that casts into the frame's shadow map: the loaded tile
/// and the copy of the world it draws in. Its models never move, so the
/// rendered shadow map serves until the set of them changes.
struct StaticModelCasterKey: Hashable {
    let tile: ObjectIdentifier
    let worldWrap: Int8
}

/// The map's own buildings a frame leaves out, by tile feature id: a model
/// drawn this frame stands in for each.
///
/// An id names a building only within a zoom. The deepest map tiles carry
/// one feature per OSM element, and the tiles above them merge buildings
/// into groups that go by the id of one member, so the same id is one
/// building in one zoom and a group of buildings in another. A model tile
/// therefore lists what it replaces zoom by zoom (`byMapTileZoom`), and a
/// map tile takes the list of its own zoom. A landmark set through the
/// settings names OSM elements with no zoom (`atEveryZoom`), and holds
/// back with its own `minimumZoom` instead.
struct ReplacedBuildings: Equatable {
    static let none = ReplacedBuildings()

    /// Left out of the map tiles of every zoom.
    var atEveryZoom: Set<UInt64> = []
    /// Left out of the map tiles of one zoom, by that zoom.
    var byMapTileZoom: [Int: Set<UInt64>] = [:]

    var isEmpty: Bool {
        atEveryZoom.isEmpty && byMapTileZoom.values.allSatisfy(\.isEmpty)
    }

    /// The ids left out of a map tile of `zoom`: the list of that zoom, and
    /// for a tile deeper than every list the deepest one, since the tiles
    /// below the archive's deepest carry the same one feature per element.
    /// A shallower tile with no list of its own takes none: its ids are
    /// groups the deeper lists know nothing of.
    func ids(forMapTileZoom zoom: Int) -> Set<UInt64> {
        var listed: Set<UInt64>?
        if let exact = byMapTileZoom[zoom] {
            listed = exact
        } else if let deepest = byMapTileZoom.keys.max(), zoom > deepest {
            listed = byMapTileZoom[deepest]
        }
        guard let listed else {
            return atEveryZoom
        }
        return atEveryZoom.isEmpty ? listed : listed.union(atEveryZoom)
    }

    mutating func formUnion(byMapTileZoom other: [Int: Set<UInt64>]) {
        for (zoom, ids) in other {
            byMapTileZoom[zoom, default: []].formUnion(ids)
        }
    }
}

struct SceneModelFrameState {
    static let empty = SceneModelFrameState(hasActiveAnimations: false,
                                            hasShadowCasters: false,
                                            hasDrawnModels: false,
                                            selectionSnapshot: .empty,
                                            pathAnimationResults: [])

    var hasActiveAnimations: Bool
    /// At least one model survived light-frustum culling this frame; feeds the
    /// shadow-pass gate together with the building-caster check.
    var hasShadowCasters: Bool
    /// At least one of those casters can move between frames (the app's
    /// scene models and the landmarks set through the settings): the shadow
    /// map is rendered again every frame while one is in it.
    var hasMovingShadowCasters = false
    /// The casters that never move, the models of the model tiles. The
    /// shadow map is rendered again when this set changes.
    var staticShadowCasters: Set<StaticModelCasterKey> = []
    /// The map's own buildings this frame leaves out (`TileBuildingRange`):
    /// a model drawn this frame stands in for each, and lists its
    /// building's outline and parts one by one. A building is named only
    /// once its model is loaded and shown, so there is never a frame with
    /// neither.
    var replacedBuildings = ReplacedBuildings.none
    /// At least one model draws in the world pass this frame.
    var hasDrawnModels: Bool
    /// Hit volumes of the models this frame drew, published after the frame
    /// reaches the screen so taps are tested against what is visible.
    var selectionSnapshot: SceneModelSelectionSnapshot
    /// Path animations that ended on this frame, with the transform they left
    /// the model at; the engine forwards them so the controller's descriptor
    /// stays truthful and the app's completion fires exactly once.
    var pathAnimationResults: [SceneModelPathAnimationResult]
}

struct MarkerFrameState {
    static let empty = MarkerFrameState(snapshot: nil)

    /// nil: no markers, nothing to publish. Empty snapshot: markers exist,
    /// but all are hidden, and the UI must hide the views.
    var snapshot: MarkerProjectionSnapshot?
}

final class FrameContextSharedState {
    var tilePlacementState: TilePlacementState = .empty
    var tileProjectionIndexState: TileProjectionIndexState = .empty
    var baseLabelState: BaseLabelState = .empty
    var baseLabelDebugBoxesState: BaseLabelDebugBoxesState = .empty
    var roadLabelState: RoadLabelState = .empty
    var avatarState: AvatarState = .empty
    var sceneModelState: SceneModelFrameState = .empty
    var markerState: MarkerFrameState = .empty
    /// Whether a label layer reads the world's depth this frame, asked in
    /// `update` (`RoadLabelDrawSubsystem`): the world pass then keeps its
    /// depth instead of dropping it when the pass ends.
    var sceneDepthForLabelsRequested = false
    /// The world's depth as the label pass reads it, single-sampled: set by
    /// the pass plan when it was kept, nil otherwise. Only the buildings and
    /// the models write real depth in it; the ground writes a band at the
    /// far plane, farther than anything real.
    var sceneDepthTexture: MTLTexture?
}
