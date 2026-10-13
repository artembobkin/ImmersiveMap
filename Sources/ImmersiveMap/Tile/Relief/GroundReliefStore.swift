// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Accelerate
import Foundation
import Metal
import os
import simd

/// The heights a flattened ground tile rises by (`Tile.metal`, the ground
/// relief variant): a terrain tile's heights in metres as a texture, and
/// where the ground tile lies in it, the terrain tile being the ground
/// tile's own or an ancestor's. With them the roughness of the place
/// (`GroundReliefRoughness`), of the tile of the roughness zoom over the
/// ground tile, and the frame's part of the strength (`GroundReliefFrame`):
/// a point of the ground rises by its height over the datum, times the
/// strength of its place at the frame's zoom.
struct GroundRelief {
    /// The terrain tile's heights (`GroundReliefTile`), the texture the
    /// vertex stages sample and the same numbers the CPU reads.
    let terrain: GroundReliefTile
    /// The ground tile's north-west corner in the texture, in 0...1.
    let origin: SIMD2<Float>
    /// The ground tile's side in the texture, in 0...1: 1 for the tile's
    /// own terrain, a half for its parent's.
    let scale: Float
    /// The roughness of the ground tile's country, and where the tile
    /// lies in it, as `origin` and `scale` in the heights.
    let roughness: GroundReliefRoughness
    let roughnessOrigin: SIMD2<Float>
    let roughnessScale: Float
    /// The frame's zoom and fades the strength is read at.
    let frame: GroundReliefFrame

    var texture: MTLTexture { terrain.texture }
    var roughnessTexture: MTLTexture { roughness.texture }

    /// The terrain's height in metres under a point of the ground tile, in
    /// the tile's uv (v from the north edge), bilinear between the texels
    /// around it, as the vertex stage samples it.
    func metres(atTileUV uv: SIMD2<Float>) -> Float {
        terrain.metres(atTextureUV: origin + simd_clamp(uv, SIMD2<Float>(repeating: 0), SIMD2<Float>(repeating: 1)) * scale)
    }

    /// How much of a mountain the ground under a point of the tile is, 0
    /// to 1, as the vertex stage samples it.
    func mountainShare(atTileUV uv: SIMD2<Float>) -> Float {
        roughness.share(atTextureUV: roughnessOrigin
                        + simd_clamp(uv, SIMD2<Float>(repeating: 0), SIMD2<Float>(repeating: 1)) * roughnessScale)
    }

    /// How much taller than the terrain the ground under a point of the
    /// tile is drawn this frame.
    func strength(atTileUV uv: SIMD2<Float>) -> Float {
        frame.strength(mountainShare: mountainShare(atTileUV: uv))
    }

    /// The metres a point of the tile is drawn at over the datum, the
    /// strength of its place in them: what to multiply by the world units
    /// per metre.
    func drawnMetres(atTileUV uv: SIMD2<Float>, datumMetres: Float) -> Float {
        (metres(atTileUV: uv) - datumMetres) * strength(atTileUV: uv)
    }

    /// Where a tile lies in the terrain tile `source` over it.
    static func placement(of tile: Tile, in source: Tile) -> (origin: SIMD2<Float>, scale: Float) {
        let depth = max(0, tile.z - source.z)
        let span = Double(1 << depth)
        let origin = SIMD2<Float>(Float((Double(tile.x) - Double(source.x) * span) / span),
                                  Float((Double(tile.y) - Double(source.y) * span) / span))
        return (origin, Float(1 / span))
    }
}

/// One terrain tile's heights: as half floats in a texture for the GPU,
/// and the same halves on the CPU for what is placed by it there (the
/// camera, the labels, the buildings' lifts). Half floats filter on every
/// GPU, so the vertex stage takes one bilinear sample, and they step by
/// half a metre at 1000 m and 2 m at 4000 m, well under the ground's grid.
final class GroundReliefTile {
    /// `r16Float`, row 0 at the north edge.
    let texture: MTLTexture
    let size: Int
    /// The texture's texels, row by row.
    let halves: [UInt16]
    /// The lowest and the highest height in the tile, in metres.
    let heightRange: ClosedRange<Float>
    /// How much of a mountain each part of the tile is, read off these
    /// heights (`GroundReliefRoughness`): the roughness of the tiles
    /// under this one where this is the roughness zoom's tile, and of
    /// this one while no coarser roughness is in.
    let roughness: GroundReliefRoughness

    init(texture: MTLTexture, size: Int, halves: [UInt16], heightRange: ClosedRange<Float>, roughness: GroundReliefRoughness) {
        self.texture = texture
        self.size = size
        self.halves = halves
        self.heightRange = heightRange
        self.roughness = roughness
    }

    var costInBytes: Int {
        texture.allocatedSize + halves.count * MemoryLayout<UInt16>.stride + roughness.costInBytes
    }

    /// The height in metres at a point of the texture, in 0...1, bilinear
    /// between the four texels around it, the texels at the edge
    /// repeating outward as the sampler clamps.
    func metres(atTextureUV uv: SIMD2<Float>) -> Float {
        let last = Float(size - 1)
        let texel = simd_clamp(uv * Float(size) - 0.5, SIMD2<Float>(repeating: 0), SIMD2<Float>(repeating: last))
        let lower = SIMD2<Int>(Int(texel.x), Int(texel.y))
        let upper = SIMD2<Int>(min(lower.x + 1, size - 1), min(lower.y + 1, size - 1))
        let blend = texel - SIMD2<Float>(Float(lower.x), Float(lower.y))
        return halves.withUnsafeBufferPointer { halves in
            let north = simd_mix(Self.float(halfBits: halves[lower.y * size + lower.x]),
                                 Self.float(halfBits: halves[lower.y * size + upper.x]),
                                 blend.x)
            let south = simd_mix(Self.float(halfBits: halves[upper.y * size + lower.x]),
                                 Self.float(halfBits: halves[upper.y * size + upper.x]),
                                 blend.x)
            return simd_mix(north, south, blend.y)
        }
    }

    /// A half float's value, by its bits: Float16 is not on every platform
    /// the package builds for.
    @inline(__always)
    static func float(halfBits bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x3FF)
        if exponent == 0 {
            // A subnormal, or zero: the mantissa over 2^24.
            return Float(sign == 0 ? 1 : -1) * Float(mantissa) * 5.960464477539063e-8
        }
        if exponent == 0x1F {
            return Float(bitPattern: sign | 0x7F80_0000 | mantissa << 13)
        }
        return Float(bitPattern: sign | UInt32(exponent + 112) << 23 | mantissa << 13)
    }
}

/// Loads the terrain tiles the flattened ground rises by
/// (`TileSettings.GroundReliefSettings`) and keeps them as textures.
///
/// A frame asks for each flattened tile it draws (`relief(for:)`). The store
/// answers with the terrain of the tile's own address, or of the deepest
/// ancestor the source has where it has none that deep, and starts loading
/// what is missing, a few at a time. Until the terrain is in, the answer is
/// nil and the tile draws flat. A terrain tile that arrives invalidates a
/// frame through `eventSink`, as a map tile does, so the on-demand render
/// loop draws it without waiting for a gesture.
///
/// A terrain tile the source does not have (an HTTP 404) is remembered as
/// missing, and the tile's ancestor is asked instead. One that could not be
/// fetched is asked again after a pause that grows with each failure. The
/// decoded tiles are kept to the memory budget, the longest unused released
/// first.
///
/// Thread-safe (`@unchecked Sendable`): the loads run in tasks off the main
/// thread and all mutable state is serialized by `lock`.
final class GroundReliefStore: @unchecked Sendable {
    static let maximumConcurrentLoads = 4
    static let retryBaseDelay: TimeInterval = 5
    static let retryMaximumDelay: TimeInterval = 60

    private static let logger = Logger(subsystem: "ImmersiveMap", category: "GroundRelief")

    /// What a terrain URL answered.
    enum Fetched: Sendable {
        case image(Data)
        /// The source has no terrain tile there.
        case missing
    }

    private enum LoadState {
        case loading(failedAttempts: Int)
        case failed(attempts: Int, retryAt: TimeInterval)
    }

    weak var eventSink: RenderFrameEventSink?

    /// The frame's part of the relief's strength (`setFrame`): the camera
    /// zoom the fades are read at, and the configured exaggeration scaled
    /// by the appear fade. How much taller than the terrain a point of
    /// the ground is drawn is this and the point's own mountain share
    /// (`GroundRelief.strength(atTileUV:)`), so a city lies flat while a
    /// mountain stands, and nothing moves with the camera but the zoom.
    private(set) var frame: GroundReliefFrame
    private let configuredExaggeration: Float
    /// The zoom of the terrain tiles the roughness is read off
    /// (`GroundReliefSettings.roughnessZoom`).
    let roughnessZoom: Int
    private let appearZoomFade: ImmersiveMapZoomFade
    private let flatZoomFade: ImmersiveMapZoomFade
    private let mountainZoomFade: ImmersiveMapZoomFade
    private let reliefWindowMetres: Float
    private let flatReliefMetres: Float
    private let mountainReliefMetres: Float

    /// The frame's camera (`RenderFrameEngine`, once a frame, before
    /// anything of the frame reads the relief): the zoom the fades are
    /// read at, and the strength scale, the configured exaggeration times
    /// the fade the relief comes in by at that zoom.
    func setFrame(cameraZoom: Double) {
        frame = GroundReliefFrame(cameraZoom: cameraZoom,
                                  strengthScale: configuredExaggeration * appearZoomFade.alpha(atZoom: cameraZoom),
                                  flatZoomFade: flatZoomFade,
                                  mountainZoomFade: mountainZoomFade)
    }

    /// The most a point of the ground is drawn taller than the terrain
    /// this frame: the strength of a mountain.
    var strengthScale: Float { frame.strengthScale }
    /// The frame's tile zoom the ground rises from
    /// (`GroundReliefSettings.fromTileZoom`): a frame of coarser tiles,
    /// and whatever stands on them, lies on the plane, and so does the
    /// camera over such a frame.
    let fromTileZoom: Int
    /// Whether the frame is on the terrain (`RenderFrameEngine`, once a
    /// frame): the flat map with tiles of the relief's zoom or deeper,
    /// at a camera zoom the relief has come in at (`comesIn(atCameraZoom:)`).
    /// Off, every tile and whatever stands on it lies on the plane, no
    /// terrain is read or loaded and the camera stands on the plane. On,
    /// every tile of the frame rises, however coarse, so no tile left on
    /// the plane cuts through the valleys under the point looked at, and
    /// the terrain is read even where the fades have scaled the relief
    /// to nothing: the fade over flat ground or the mountains is told by
    /// the terrain itself, which has to be in to tell.
    private(set) var isActive = true

    /// Whether the relief has come in at a camera zoom
    /// (`GroundReliefSettings.appearZoomFade`): past the fade's start.
    func comesIn(atCameraZoom zoom: Double) -> Bool {
        appearZoomFade.alpha(atZoom: zoom) > 0
    }
    /// The least height the camera keeps over the relief under it.
    let cameraClearanceMetres: Float
    /// The terrain under the point the camera looks at this frame, in
    /// metres before the exaggeration (`GroundReliefCameraLift.datumMetres`):
    /// the height the relief is drawn from. The ground, the buildings and
    /// the labels rise by their terrain's height over it, so that point
    /// lies at the world's origin, on the ground, and the camera's pose,
    /// made for the plane, holds unchanged. Zero while the camera is over
    /// tiles coarser than the relief's zoom, or over the globe. Kept
    /// while the terrain under the point is on its way.
    private(set) var datumMetres: Float = 0

    private let device: MTLDevice
    private let tileURLTemplate: String
    private let encoding: ImmersiveMapSettings.TileSettings.GroundReliefEncoding
    private let minimumSourceZoom: Int
    private let fetch: @Sendable (URL) async throws -> Fetched
    private let now: @Sendable () -> TimeInterval

    private let lock = NSLock()
    private var terrains: LRUMemoryCache<Tile, GroundReliefTile>
    /// Grows with every terrain tile that arrives or leaves: what is
    /// placed by the terrain on the CPU (the labels) is placed again when
    /// it changes.
    private(set) var version: UInt64 = 0
    private var missingTiles: Set<Tile> = []
    private var statesByTile: [Tile: LoadState] = [:]
    private var activeLoads = 0
    private var heightRange: ClosedRange<Float>?
    private var heightRangeVersion: UInt64?

    /// The lowest and the highest height over every terrain tile in, in
    /// metres before the exaggeration, nil with none in. The coarse tiles
    /// of the far rings span the region around the camera, so the range
    /// is the region's, the peaks not yet drawn included. The coverage
    /// walks the frustum's footprint over this range of ground
    /// (`CoveragePolygonBuilder`), so a tile the relief lifts into view
    /// past the plane's footprint is drawn.
    var heightRangeMetres: ClosedRange<Float>? {
        lock.lock()
        defer { lock.unlock() }
        if heightRangeVersion != version {
            var range: ClosedRange<Float>?
            for key in terrains.keys {
                guard let tile = terrains.peekValue(forKey: key) else { continue }
                range = range.map { min($0.lowerBound, tile.heightRange.lowerBound) ... max($0.upperBound, tile.heightRange.upperBound) }
                    ?? tile.heightRange
            }
            heightRange = range
            heightRangeVersion = version
        }
        return heightRange
    }
    /// The store of a map's settings: nil while the relief is off.
    static func make(settings: ImmersiveMapSettings, device: MTLDevice) -> GroundReliefStore? {
        let relief = settings.tiles.groundRelief
        guard relief.isEnabled else {
            return nil
        }
        return GroundReliefStore(device: device, settings: relief)
    }

    /// The test seam: the terrain bytes from a closure, and a clock.
    init(device: MTLDevice,
         settings: ImmersiveMapSettings.TileSettings.GroundReliefSettings,
         fetch: @escaping @Sendable (URL) async throws -> Fetched = GroundReliefStore.fetchOverHTTP,
         now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.device = device
        self.configuredExaggeration = settings.exaggeration
        self.appearZoomFade = settings.appearZoomFade
        self.flatZoomFade = settings.flatZoomFade
        self.mountainZoomFade = settings.mountainZoomFade
        self.reliefWindowMetres = max(settings.reliefWindowMetres, 1)
        self.flatReliefMetres = max(settings.flatReliefMetres, 0)
        self.mountainReliefMetres = max(settings.mountainReliefMetres, settings.flatReliefMetres)
        self.roughnessZoom = max(0, settings.roughnessZoom)
        // Until the first frame: the relief as configured, no fade.
        self.frame = GroundReliefFrame(cameraZoom: 0,
                                       strengthScale: settings.exaggeration,
                                       flat: GroundReliefFrame.noFade,
                                       mountain: GroundReliefFrame.noFade)
        self.fromTileZoom = settings.fromTileZoom
        self.cameraClearanceMetres = max(0, settings.cameraClearanceMetres)
        self.tileURLTemplate = settings.tileURLTemplate
        self.encoding = settings.encoding
        self.minimumSourceZoom = max(0, settings.minimumSourceZoom)
        self.terrains = LRUMemoryCache(costLimit: max(0, settings.memoryBudgetInBytes))
        self.fetch = fetch
        self.now = now
    }

    /// The frame's datum (`RenderFrameEngine`, once a frame).
    func setDatum(metres: Float) {
        datumMetres = metres
    }

    /// Whether the frame is on the terrain (`RenderFrameEngine`, once a
    /// frame).
    func setActive(_ isActive: Bool) {
        self.isActive = isActive
    }

    /// The zoom a ring reads its terrain at: one coarser than the ring's
    /// own tiles. The terrain is the ring's, not the tile's: whatever
    /// stands in a ring's slot, the tile itself or a stand-in while it
    /// loads, is raised by the same terrain, so a tile landing changes
    /// the fills and never the ground's shape, and the whole ring moves to
    /// the next terrain at once, at the zoom crossing, as its tiles do. A
    /// coarser stand-in, the parent, can read that terrain too, which it
    /// could not read one of its own zoom (four terrain tiles under one
    /// ground tile). The datum and the camera read the first ring's. A
    /// terrain tile is 512 heights across and a ground tile's grid at most
    /// 128 cells, so the coarser terrain is still finer than the grid that
    /// samples it, at a quarter of the tiles.
    static func terrainZoom(forTargetZoom zoom: Int) -> Int {
        max(zoom - 1, 0)
    }

    /// The camera's terrain (`CameraTerrainFollow`): a pan keeps the eye's
    /// height by the zoom, and the zoom stops at the clearance over a
    /// ridge. The terrain is read at the zoom the frame's datum and ground
    /// read it at (`GroundReliefCameraLift.datumMetres`), the zoom of the
    /// tiles a frame at `cameraZoom` draws: a coarser zoom's terrain is
    /// another tile with other heights, and a camera held level by one
    /// while the ground is drawn by the other bobs by their difference.
    /// The terrain is read as drawn (`drawnMetres`), at the strength of
    /// each place. The camera over tiles coarser than the relief's zoom
    /// is over the plane, like the tiles.
    func makeTerrainFollow(tileSettings: ImmersiveMapSettings.TileSettings,
                           globeRadiusScale: Double,
                           cameraZoom: @escaping () -> Double) -> CameraTerrainFollow {
        return CameraTerrainFollow(
            terrainMetres: { [weak self] point in
                guard let self else { return nil }
                let tileZoom = tileSettings.resolvedCoverageZoomLevel(forCameraZoom: cameraZoom())
                guard tileZoom >= self.fromTileZoom else {
                    return 0
                }
                return self.drawnMetres(atNormalizedWorld: point, terrainZoom: Self.terrainZoom(forTargetZoom: tileZoom))
            },
            clearanceMetres: Double(cameraClearanceMetres),
            globeRadiusScale: globeRadiusScale)
    }

    /// The relief of a ground tile, read out of the terrain of
    /// `terrainZoom`, the ring's (`terrainZoom(forTargetZoom:)`), or of
    /// the tile's own zoom when that is coarser: a terrain tile covers one
    /// ground tile at most. While that terrain is on its way, the finest
    /// coarser terrain already in, which the tile is drawn with until it
    /// lands and refines it. Starts the load of what is missing. Nil while
    /// no terrain over the tile is in at all, or the source has none, and
    /// nil while the frame is off the terrain (`isActive`), where every
    /// tile lies on the plane, as does a tile with no terrain over it
    /// in at all, until one lands (`TileWorkingSetSubsystem`). The
    /// stand-in may be coarser than the source's floor
    /// (`minimumSourceZoom`): the floor is where a missing tile's search
    /// for one that exists ends, not a limit on what may stand in. No
    /// load starts below the floor. `orCoarser` false asks for the
    /// terrain of `terrainZoom` only.
    func relief(for tile: Tile, terrainZoom: Int, orCoarser: Bool = true) -> GroundRelief? {
        guard isActive else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        var source = tile.findParentTile(atZoom: max(min(terrainZoom, tile.z), 0)) ?? tile
        // Past a source on its way, only what is in stands in: nothing
        // else is asked for.
        var standInOnly = false
        while true {
            if let terrain = terrains.value(forKey: source) {
                let placement = GroundRelief.placement(of: tile, in: source)
                let roughness = roughnessSourceLocked(for: tile, heights: source, terrain: terrain)
                let roughnessPlacement = GroundRelief.placement(of: tile, in: roughness.tile)
                return GroundRelief(terrain: terrain,
                                    origin: placement.origin,
                                    scale: placement.scale,
                                    roughness: roughness.terrain.roughness,
                                    roughnessOrigin: roughnessPlacement.origin,
                                    roughnessScale: roughnessPlacement.scale,
                                    frame: frame)
            }
            if standInOnly == false, missingTiles.contains(source) == false {
                switch statesByTile[source] {
                case .loading:
                    break
                case .failed(let attempts, let retryAt):
                    if now() >= retryAt, activeLoads < Self.maximumConcurrentLoads {
                        startLoad(source, failedAttempts: attempts)
                    }
                case nil:
                    if activeLoads < Self.maximumConcurrentLoads {
                        startLoad(source, failedAttempts: 0)
                    }
                }
                guard orCoarser else {
                    return nil
                }
                standInOnly = true
            }
            if standInOnly == false, source.z <= minimumSourceZoom {
                // Missing at the floor: the source has nothing over the tile.
                return nil
            }
            guard source.z > 0, let parent = source.findParentTile(atZoom: source.z - 1) else {
                return nil
            }
            source = parent
        }
    }

    /// The terrain tile the roughness of a ground tile is read off: the
    /// tile of the roughness zoom over it, or the ground tile's own zoom
    /// where that is coarser, whose load starts here, or, while that is
    /// on its way, the finest coarser one in, and, with none in at all,
    /// the heights' own tile, which has a roughness of its own country.
    /// Called under `lock`.
    private func roughnessSourceLocked(for tile: Tile, heights: Tile, terrain: GroundReliefTile) -> (tile: Tile, terrain: GroundReliefTile) {
        var source = tile.findParentTile(atZoom: max(min(roughnessZoom, tile.z), 0)) ?? tile
        var asked = false
        while true {
            if let resident = terrains.value(forKey: source) {
                return (source, resident)
            }
            if asked == false, missingTiles.contains(source) == false {
                switch statesByTile[source] {
                case .loading:
                    break
                case .failed(let attempts, let retryAt):
                    if now() >= retryAt, activeLoads < Self.maximumConcurrentLoads {
                        startLoad(source, failedAttempts: attempts)
                    }
                case nil:
                    if activeLoads < Self.maximumConcurrentLoads {
                        startLoad(source, failedAttempts: 0)
                    }
                }
                asked = true
            }
            guard source.z > 0, let parent = source.findParentTile(atZoom: source.z - 1) else {
                return (heights, terrain)
            }
            source = parent
        }
    }

    /// The relief under a point of the world (normalized world mercator),
    /// from the terrain tile of `terrainZoom` that holds it, or the finest
    /// coarser one in while that one is on its way: nil while no terrain
    /// over the point is in, and nil while the frame is off the terrain
    /// (`isActive`), on the plane. With it the point's uv in the tile.
    private func relief(atNormalizedWorld point: SIMD2<Double>, terrainZoom zoom: Int) -> (relief: GroundRelief, uv: SIMD2<Float>)? {
        let tilesCount = Double(1 << max(0, zoom))
        let wrappedX = ImmersiveMapProjection.wrapNormalizedWorldX(point.x)
        let clampedY = ImmersiveMapProjection.clampNormalizedWorldY(point.y)
        let column = min(Int(wrappedX * tilesCount), Int(tilesCount) - 1)
        let row = min(Int(clampedY * tilesCount), Int(tilesCount) - 1)
        guard let relief = relief(for: Tile(x: column, y: row, z: zoom), terrainZoom: zoom) else {
            return nil
        }
        return (relief, SIMD2<Float>(Float(wrappedX * tilesCount - Double(column)), Float(clampedY * tilesCount - Double(row))))
    }

    /// The terrain's height in metres under a point of the world, from
    /// the terrain tile of `terrainZoom` that holds it: bilinear between
    /// the four texels around it, as the vertex stage samples it. From
    /// the finest coarser terrain in while that one is on its way, nil
    /// while no terrain over the point is in, and zero while the frame is
    /// off the terrain (`isActive`), on the plane.
    func elevation(atNormalizedWorld point: SIMD2<Double>, terrainZoom zoom: Int) -> Float? {
        guard isActive else {
            return 0
        }
        guard let found = relief(atNormalizedWorld: point, terrainZoom: zoom) else {
            return nil
        }
        return found.relief.metres(atTileUV: found.uv)
    }

    /// How much of a mountain the ground under a point of the world is, 0
    /// to 1 (`GroundReliefRoughness`): zero off the terrain, nil while no
    /// terrain over the point is in.
    func mountainShare(atNormalizedWorld point: SIMD2<Double>, terrainZoom zoom: Int) -> Float? {
        guard isActive else {
            return 0
        }
        guard let found = relief(atNormalizedWorld: point, terrainZoom: zoom) else {
            return nil
        }
        return found.relief.mountainShare(atTileUV: found.uv)
    }

    /// How much taller than the terrain the ground under a point of the
    /// world is drawn this frame, by the roughness of the place: zero off
    /// the terrain, nil while no terrain over the point is in.
    func strength(atNormalizedWorld point: SIMD2<Double>, terrainZoom zoom: Int) -> Float? {
        guard isActive else {
            return 0
        }
        guard let found = relief(atNormalizedWorld: point, terrainZoom: zoom) else {
            return nil
        }
        return found.relief.strength(atTileUV: found.uv)
    }

    /// The terrain under a point of the world as drawn: the datum plus
    /// the height over it at the strength of the place, in metres, so the
    /// point the camera looks at reads as its own height and the country
    /// around it as high as it is drawn. Nil while no terrain over the
    /// point is in, zero off the terrain.
    func drawnMetres(atNormalizedWorld point: SIMD2<Double>, terrainZoom zoom: Int) -> Float? {
        guard isActive else {
            return 0
        }
        guard let found = relief(atNormalizedWorld: point, terrainZoom: zoom) else {
            return nil
        }
        return datumMetres + found.relief.drawnMetres(atTileUV: found.uv, datumMetres: datumMetres)
    }

    /// The world units a metre of terrain rises by over a tile: the world
    /// units per metre at the tile's latitude. The strength of a place is
    /// not in it (`GroundRelief.strength(atTileUV:)`).
    func worldUnitsPerMetre(over tile: Tile, renderMapSize: Double) -> Float {
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: (Double(tile.y) + 0.5) / Double(1 << tile.z))
        return Float(ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: latitude, renderMapSize: renderMapSize))
    }

    /// Half floats' values.
    static func floats(halfBits bits: [UInt16]) -> [Float] {
        bits.map(GroundReliefTile.float(halfBits:))
    }

    /// Releases every terrain tile, for a memory warning. The tiles still
    /// drawn load again.
    func removeAll() {
        lock.lock()
        _ = terrains.removeAll()
        version &+= 1
        lock.unlock()
    }

    /// The URL of a terrain tile.
    func url(for tile: Tile) -> URL? {
        URL(string: tileURLTemplate
            .replacingOccurrences(of: "{z}", with: String(tile.z))
            .replacingOccurrences(of: "{x}", with: String(tile.x))
            .replacingOccurrences(of: "{y}", with: String(tile.y)))
    }

    /// The terrain at a URL: an HTTP 404, or a file that is not there for a
    /// terrain directory on disk, is a tile the source does not have.
    static func fetchOverHTTP(_ url: URL) async throws -> Fetched {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch let error as URLError where error.code == .fileDoesNotExist {
            return .missing
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .missing
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        switch status {
        case 200 ..< 300:
            return .image(data)
        case 404:
            return .missing
        default:
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - Loading

    /// Called under `lock`.
    private func startLoad(_ tile: Tile, failedAttempts: Int) {
        statesByTile[tile] = .loading(failedAttempts: failedAttempts)
        activeLoads += 1
        guard let url = url(for: tile) else {
            finishLoad(tile, terrain: nil, locked: true)
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                switch try await self.fetch(url) {
                case .image(let data):
                    let terrain = try self.makeTerrain(GroundReliefDecoder.decode(data, encoding: self.encoding), tile: tile)
                    self.finishLoad(tile, terrain: terrain, locked: false)
                case .missing:
                    self.finishLoad(tile, terrain: nil, locked: false)
                }
            } catch let error as GroundReliefDecoder.Failure {
                Self.logger.warning("ImmersiveMap: terrain tile \(tile.z, privacy: .public)/\(tile.x, privacy: .public)/\(tile.y, privacy: .public) cannot be decoded (\(String(describing: error), privacy: .public)). Check that groundRelief(tileURLTemplate:) serves Terrarium images.")
                self.finishLoad(tile, terrain: nil, locked: false)
            } catch {
                self.failLoad(tile)
            }
        }
    }

    /// The heights as half floats, in a texture for the GPU and on the
    /// CPU, and the roughness of the tile's country read off them.
    private func makeTerrain(_ heights: GroundReliefHeights, tile: Tile) throws -> GroundReliefTile {
        let size = heights.size
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float,
                                                                  width: size,
                                                                  height: size,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw URLError(.cannotCreateFile)
        }
        var halves = [UInt16](repeating: 0, count: size * size)
        var metres = heights.metres
        metres.withUnsafeMutableBytes { source in
            halves.withUnsafeMutableBytes { destination in
                var sourceBuffer = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(size),
                                                 width: vImagePixelCount(size), rowBytes: size * 4)
                var destinationBuffer = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(size),
                                                      width: vImagePixelCount(size), rowBytes: size * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&sourceBuffer, &destinationBuffer, vImage_Flags(kvImageNoFlags))
            }
        }
        halves.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, size, size),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: size * MemoryLayout<UInt16>.stride)
        }
        var lowest: Float = 0
        var highest: Float = 0
        vDSP_minv(heights.metres, 1, &lowest, vDSP_Length(heights.metres.count))
        vDSP_maxv(heights.metres, 1, &highest, vDSP_Length(heights.metres.count))
        guard let roughness = GroundReliefRoughness.make(heights: heights,
                                                         tile: tile,
                                                         windowMetres: reliefWindowMetres,
                                                         flatMetres: flatReliefMetres,
                                                         mountainMetres: mountainReliefMetres,
                                                         device: device) else {
            throw URLError(.cannotCreateFile)
        }
        return GroundReliefTile(texture: texture,
                                size: size,
                                halves: halves,
                                heightRange: min(lowest, highest) ... max(lowest, highest),
                                roughness: roughness)
    }

    /// A load that ended: the terrain, or nil for a tile the source does
    /// not have (or cannot be read), which is then remembered as missing.
    private func finishLoad(_ tile: Tile, terrain: GroundReliefTile?, locked: Bool) {
        if locked == false {
            lock.lock()
        }
        statesByTile.removeValue(forKey: tile)
        activeLoads -= 1
        if let terrain {
            _ = terrains.setValue(terrain, forKey: tile, cost: terrain.costInBytes)
            version &+= 1
        } else {
            missingTiles.insert(tile)
        }
        if locked == false {
            lock.unlock()
        }
        // A missing tile changes no picture, but the next frame asks for
        // its ancestor.
        eventSink?.invalidate(.tileAvailable)
    }

    private func failLoad(_ tile: Tile) {
        lock.lock()
        var attempts = 1
        if case .loading(let failedAttempts) = statesByTile[tile] {
            attempts = failedAttempts + 1
        }
        let delay = min(Self.retryMaximumDelay, Self.retryBaseDelay * pow(2, Double(attempts - 1)))
        statesByTile[tile] = .failed(attempts: attempts, retryAt: now() + delay)
        activeLoads -= 1
        lock.unlock()

        // The pause's end must draw a frame: on-demand rendering would
        // otherwise wait for a gesture.
        eventSink?.invalidate(.tileAvailable)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.eventSink?.invalidate(.tileAvailable)
        }
    }
}
