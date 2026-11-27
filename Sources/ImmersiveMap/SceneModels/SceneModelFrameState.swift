// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

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
/// map tile takes the list of its own zoom.
struct ReplacedBuildings: Equatable {
    static let none = ReplacedBuildings()

    /// Left out of the map tiles of one zoom, by that zoom.
    var byMapTileZoom: [Int: Set<UInt64>] = [:]

    var isEmpty: Bool {
        byMapTileZoom.values.allSatisfy(\.isEmpty)
    }

    /// The ids left out of a map tile of `zoom`: the list of that zoom, and
    /// for a tile deeper than every list the deepest one, since the tiles
    /// below the archive's deepest carry the same one feature per element.
    /// A shallower tile with no list of its own takes none: its ids are
    /// groups the deeper lists know nothing of.
    func ids(forMapTileZoom zoom: Int) -> Set<UInt64> {
        if let exact = byMapTileZoom[zoom] {
            return exact
        }
        if let deepest = byMapTileZoom.keys.max(), zoom > deepest {
            return byMapTileZoom[deepest] ?? []
        }
        return []
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
                                            pathAnimationResults: [])

    var hasActiveAnimations: Bool
    /// At least one model survived light-frustum culling this frame; feeds the
    /// shadow-pass gate together with the building-caster check.
    var hasShadowCasters: Bool
    /// At least one of those casters can move between frames (the app's
    /// scene models): the shadow
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
    /// Path animations that ended on this frame, with the transform they left
    /// the model at; the engine forwards them so the controller's descriptor
    /// stays truthful and the app's completion fires exactly once.
    var pathAnimationResults: [SceneModelPathAnimationResult]
}

extension SceneModelFrameState: FrameState {
    init() {
        self = .empty
    }
}

/// What the model tiles tell the frame (`FrameStateBoard`), set in `update`
/// by `ModelTileRenderSubsystem`.
struct ModelTileFrameState: FrameState {
    /// The model tiles (`ModelTileStore.tileZoom`) still on their way this
    /// frame: the buildings under them wait, so the ones a model stands in
    /// for are left out from their first frame instead of standing until
    /// the model comes.
    var pendingTiles: Set<Tile> = []
    /// What changes while the models rise: the shadow map is drawn again
    /// while it does.
    var riseSignature: Float = 0
}
