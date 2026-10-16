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
/// tile's own or an ancestor's. With them the frame's strength: a point
/// of the ground rises by its height over the datum, times the strength
/// the frame's zoom leaves of the relief (`GroundReliefStore.setFrame`).
struct GroundRelief {
    /// The terrain tile's heights (`GroundReliefTile`), the texture the
    /// vertex stages sample and the same numbers the CPU reads.
    let terrain: GroundReliefTile
    /// The ground tile's north-west corner in the texture, in 0...1.
    let origin: SIMD2<Float>
    /// The ground tile's side in the texture, in 0...1: 1 for the tile's
    /// own terrain, a half for its parent's.
    let scale: Float
    /// How much taller than the terrain the ground is drawn this frame:
    /// the configured exaggeration times what the zoom fades leave.
    let strength: Float

    var texture: MTLTexture { terrain.texture }

    /// The terrain's height in metres under a point of the ground tile, in
    /// the tile's uv (v from the north edge), bilinear between the texels
    /// around it, as the vertex stage samples it.
    func metres(atTileUV uv: SIMD2<Float>) -> Float {
        terrain.metres(atTextureUV: origin + simd_clamp(uv, SIMD2<Float>(repeating: 0), SIMD2<Float>(repeating: 1)) * scale)
    }

    /// The metres a point of the tile is drawn at over the datum, the
    /// frame's strength in them: what to multiply by the world units per
    /// metre.
    func drawnMetres(atTileUV uv: SIMD2<Float>, datumMetres: Float) -> Float {
        (metres(atTileUV: uv) - datumMetres) * strength
    }

    /// The same heights over `part`, a square inside the ground tile
    /// `tile` this relief is over: what draws a part of the tile on its own
    /// grid and lifts it exactly as the whole tile's draw does.
    func narrowed(to part: Tile, in tile: Tile) -> GroundRelief {
        let inner = Self.placement(of: part, in: tile)
        return GroundRelief(terrain: terrain,
                            origin: origin + inner.origin * scale,
                            scale: scale * inner.scale,
                            strength: strength)
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
///
/// The edges are welded to the neighbours' of the same zoom once they are
/// in (`GroundReliefEdgeWeld`): the texels along an edge take the mean of
/// the tile's and its neighbour's, the height that lies on the edge
/// itself, so two tiles meet there with one height and the ground drawn
/// over them closes. The texels change in place, written on the main
/// thread only (`GroundReliefStore.applyPendingWelds`), as everything that
/// reads them reads there.
final class GroundReliefTile {
    /// `r16Float`, row 0 at the north edge.
    let texture: MTLTexture
    let size: Int
    /// The texture's texels, row by row, with the edges as welded.
    private(set) var halves: [UInt16]
    /// The edges as decoded, which every weld averages from, so the weld
    /// is the same whatever order the neighbours came in.
    let originalEdges: Edges
    /// The lowest and the highest height in the tile, in metres, the
    /// welded edges included.
    private(set) var heightRange: ClosedRange<Float>
    /// Grows with every weld written into the texels: what was placed by
    /// them on the CPU (the buildings' lifts) is placed again.
    private(set) var revision: UInt64 = 0

    /// A tile's four edges, `size` texels each: the north and the south
    /// rows west to east, the west and the east columns north to south.
    struct Edges {
        let north: [UInt16]
        let south: [UInt16]
        let west: [UInt16]
        let east: [UInt16]
    }

    init(texture: MTLTexture, size: Int, halves: [UInt16], heightRange: ClosedRange<Float>) {
        self.texture = texture
        self.size = size
        self.halves = halves
        self.heightRange = heightRange
        self.originalEdges = Edges(north: Array(halves[0 ..< size]),
                                   south: Array(halves[(size - 1) * size ..< size * size]),
                                   west: (0 ..< size).map { halves[$0 * size] },
                                   east: (0 ..< size).map { halves[$0 * size + size - 1] })
    }

    var costInBytes: Int {
        texture.allocatedSize + (halves.count + size * 4) * MemoryLayout<UInt16>.stride
    }

    /// Writes texels of a welded edge on the CPU, a rectangle of `width` by
    /// `height` from the column `x` and the row `y`, row by row: the
    /// texture takes the same through the GPU
    /// (`GroundReliefStore.applyPendingWelds`). Main thread only.
    func writeTexels(_ values: [UInt16], x: Int, y: Int, width: Int, height: Int) {
        var lowest = heightRange.lowerBound
        var highest = heightRange.upperBound
        for row in 0 ..< height {
            for column in 0 ..< width {
                let value = values[row * width + column]
                halves[(y + row) * size + x + column] = value
                let metres = Self.float(halfBits: value)
                lowest = min(lowest, metres)
                highest = max(highest, metres)
            }
        }
        heightRange = lowest ... highest
        revision &+= 1
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
/// The frame states once which terrain tiles it needs, nearest first
/// (`request(tiles:)`, `GroundReliefDemand`), as it states its map tiles:
/// the store loads them in that order, a few at a time
/// (`GroundReliefSettings.maximumConcurrentLoads`), and keeps them while
/// they are wanted. Whatever reads the terrain (`relief(for:)`, the point
/// lookups) only reads: it answers with the terrain of the tile's own
/// address or, while that is on its way, the finest coarser one in, and
/// never starts a load. Until any terrain over the tile is in, the answer
/// is nil and the tile draws flat. A terrain tile that arrives invalidates
/// a frame through `eventSink`, as a map tile does, so the on-demand
/// render loop draws it without waiting for a gesture. Its edges are
/// welded to its neighbours' of the same zoom (`GroundReliefEdgeWeld`), so
/// the ground over two tiles meets without a crack, written at the next
/// frame's start (`applyPendingWelds`).
///
/// A terrain tile the source does not have (an HTTP 404) is remembered as
/// missing, and its ancestor is wanted in its place, down to the source's
/// floor. One that could not be fetched is asked again after a pause that
/// grows with each failure. A load the camera has left behind finishes,
/// as a map tile's does, and its tile stays as a cached one. The decoded
/// tiles are kept to the memory budget, the wanted ones whatever they
/// cost, the others released longest unused first. `statusSnapshot()`
/// tells the debug panel all of it.
///
/// Thread-safe (`@unchecked Sendable`): the loads run in tasks off the main
/// thread and all mutable state is serialized by `lock`.
///
/// The main type of `Tile/Relief`, the relief's core. The relief draws
/// nothing of its own: it changes how other features draw, so its code
/// lies in a `Relief` folder of each feature it changes, and this folder
/// holds what they all share: the terrain tiles and their store, the
/// heights read on the CPU (`GroundRelief`, `GroundReliefTileLift`), the
/// frame's datum (`GroundReliefCameraLift`), the GPU side every rising
/// draw binds (`GroundReliefUniform`, `Shaders/GroundRelief.h`), and the
/// relief of the tile's own features, the ground and the buildings
/// (`BuildingReliefLifts`). It holds no drawing and no parsing, and
/// depends on nothing of a feature but the tile's address. The other
/// features' relief lies in their own `Relief` folders
/// (`Camera/Relief`), and a feature whose relief is a call into this
/// core (the labels) keeps the call where it is.
final class GroundReliefStore: @unchecked Sendable {
    /// How many terrain tiles load at once
    /// (`GroundReliefSettings.maximumConcurrentLoads`).
    let maximumConcurrentLoads: Int
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

    /// How much taller than the terrain the ground is drawn this frame
    /// (`setFrame`): the configured exaggeration times the standing
    /// share, eased, the same everywhere, so nothing moves with the
    /// camera but the zoom's crossing of a threshold.
    private(set) var strengthScale: Float
    /// How much of the relief stands: 1 standing, 0 lying in the plane,
    /// between them on its way over `transitionSeconds`, up when the
    /// zoom entered the relief's zooms (`GroundReliefSettings.appearZoom`
    /// to `collapseZoom`) and down when it left them. Never a function of
    /// the zoom itself: a relief scaled with the zoom breathes with every
    /// drag over the terrain, whose slopes move the zoom.
    private(set) var standingShare: Float = 1
    /// The standing share eased as the relief rises and collapses
    /// (`setFrame`): what the strength and the hillshade scale by.
    private(set) var risenShare: Float = 1
    /// How the slopes are shaded (`ImmersiveMapHillshade`, the style's) and
    /// the scene's light they are shaded by this frame (`setLight`).
    private let hillshadeStyle: ImmersiveMapHillshade
    private var lightDirection = ImmersiveMapSettings.SceneLightSettings().direction
    private var cameraEye = SIMD3<Float>(0, 0, 1)
    private var hillshadeFadeCameraDistances: ClosedRange<Float>?
    /// The shading of the slopes this frame, what every draw on the relief
    /// binds (`GroundReliefUniform`): the scene's light and the style's
    /// intensity at the share of the relief that has risen, so the shading
    /// rises and collapses with the relief.
    private(set) var hillshade: GroundReliefHillshade = .none
    /// Whether the rise or the collapse is under way this frame: the
    /// frames keep coming while it is (`RenderFrameEngine`).
    var isTransitioning: Bool { standingShare > 0 && standingShare < 1 }
    private let configuredExaggeration: Float
    private let appearZoom: Double
    private let collapseZoom: Double
    private let transitionSeconds: TimeInterval
    /// Which terrain tiles the ground and the camera read, by the
    /// relief's detail (`GroundReliefSettings.detail`).
    let zooms: GroundReliefTerrainZooms
    /// The zoom of the terrain tiles the camera and the frame's datum read
    /// (`GroundReliefSettings.cameraTerrainZoom`, the detail's own when
    /// unset).
    var cameraTerrainZoom: Int { zooms.cameraZoom }

    /// The frame's zoom (`RenderFrameEngine`, once a frame, before
    /// anything of the frame reads the relief): the zoom held through a
    /// drag, the camera's otherwise. The relief moves toward standing
    /// when the zoom is within its zooms and toward the plane when it is
    /// not, by `deltaTime` over `transitionSeconds`, or at once with
    /// `snap`. Without a `deltaTime` it is settled where the zoom puts
    /// it.
    func setFrame(zoom: Double, deltaTime: TimeInterval? = nil, snap: Bool = false) {
        let target: Float = stands(atZoom: zoom) ? 1 : 0
        if let deltaTime, snap == false, transitionSeconds > 0 {
            let step = Float(max(deltaTime, 0) / transitionSeconds)
            standingShare = target > standingShare ? min(standingShare + step, target) : max(standingShare - step, target)
        } else {
            standingShare = target
        }
        let eased = standingShare * standingShare * (3 - 2 * standingShare)
        risenShare = eased
        strengthScale = configuredExaggeration * eased
        resolveHillshade()
    }

    /// The scene's light this frame (`SceneLightSettings.direction`, toward
    /// the light, `RenderFrameEngine`), which the slopes are shaded by, and
    /// the eye they fade with the distance from. `fadeCameraDistances`
    /// replaces the style's fade (the debug panel's), nil keeps it.
    func setLight(direction: SIMD3<Float>,
                  cameraEye: SIMD3<Float>,
                  fadeCameraDistances: ClosedRange<Float>? = nil) {
        lightDirection = direction
        self.cameraEye = cameraEye
        hillshadeFadeCameraDistances = fadeCameraDistances
        resolveHillshade()
    }

    private func resolveHillshade() {
        hillshade = GroundReliefHillshade.resolve(style: hillshadeStyle,
                                                  lightDirection: lightDirection,
                                                  risenShare: risenShare,
                                                  cameraEye: cameraEye,
                                                  fadeCameraDistances: hillshadeFadeCameraDistances)
    }

    /// Whether the relief stands at a zoom: from `appearZoom` up to
    /// `collapseZoom`.
    func stands(atZoom zoom: Double) -> Bool {
        zoom >= appearZoom && zoom < collapseZoom
    }
    /// The frame's tile zoom the ground rises from, the tile zoom of
    /// `GroundReliefSettings.appearZoom` (`tileZoom(deepestTileZoom:)`), the
    /// zoom the ground is flattened from too: a frame of coarser tiles, and
    /// whatever stands on them, lies on the plane, and so does the camera
    /// over such a frame.
    let fromTileZoom: Int
    /// Whether the frame is on the terrain (`RenderFrameEngine`, once a
    /// frame): the flat map with tiles of the relief's zoom or deeper,
    /// at a zoom within the relief's zooms or on its way out of them
    /// (`isVisible(atZoom:)`). Off, every tile and whatever stands
    /// on it lies on the plane, no terrain is read or loaded and the
    /// camera stands on the plane. On, every tile of the frame rises,
    /// however coarse, so no tile left on the plane cuts through the
    /// valleys under the point looked at.
    private(set) var isActive = true

    /// Whether anything of the relief stands at a zoom (the zoom held
    /// through a drag, the camera's otherwise): within its zooms, or
    /// still on its way into the plane.
    func isVisible(atZoom zoom: Double) -> Bool {
        stands(atZoom: zoom) || standingShare > 0
    }
    /// The least height the camera keeps over the relief under it.
    let cameraClearanceMetres: Float
    /// Whether the mountains may cast their shadows
    /// (`GroundReliefSettings.castsShadows`, the debug panel's over it),
    /// set once a frame (`setCastsShadows`).
    private var castsShadowsEnabled = false

    /// Whether the mountains may cast their shadows this frame
    /// (`RenderFrameEngine`, once a frame).
    func setCastsShadows(_ isEnabled: Bool) {
        castsShadowsEnabled = isEnabled
    }

    /// Whether the mountains cast into the shadow map this frame
    /// (`GroundReliefShadowCasterSubsystem`): allowed to, on the terrain,
    /// and risen. It opens the shadow pass as a building does
    /// (`ShadowPassGateResolver`).
    var castsShadowsThisFrame: Bool {
        castsShadowsEnabled && isActive && strengthScale > 0
    }

    /// What the mountains' shadow in the map is drawn from: the terrain
    /// tiles in and their welds (`version`), the rise, the world scale and
    /// the datum the ground is drawn from. The map is drawn again when it
    /// changes (`ShadowMapReuseController`), nil while the mountains cast
    /// nothing.
    struct ShadowSignature: Equatable {
        let version: UInt64
        let strength: Float
        let worldUnitsPerMetre: Float
        let datumMetres: Float
    }

    var shadowSignature: ShadowSignature? {
        guard castsShadowsThisFrame else { return nil }
        lock.lock()
        let version = version
        lock.unlock()
        return ShadowSignature(version: version,
                               strength: strengthScale,
                               worldUnitsPerMetre: worldUnitsPerMetre,
                               datumMetres: datumMetres)
    }
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
    /// The frame's demand (`request(tiles:)`), nearest first, and the same
    /// as a set: loaded in that order, never released.
    private var wantedOrder: [Tile] = []
    private var wantedTiles: Set<Tile> = []
    /// When each load started, for the debug panel.
    private var loadStartedAt: [Tile: TimeInterval] = [:]
    /// The welds of the tiles' edges to their neighbours' still to write
    /// (`GroundReliefEdgeWeld`), queued as the tiles arrive and written at
    /// the next frame's start (`applyPendingWelds`).
    private var pendingWelds: [GroundReliefEdgeWeld.Write] = []
    private let memoryBudgetInBytes: Int
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
    /// `hillshade` is the style's (`MapStyleRuntime.hillshade`).
    static func make(settings: ImmersiveMapSettings,
                     hillshade: ImmersiveMapHillshade,
                     device: MTLDevice) -> GroundReliefStore? {
        let relief = settings.tiles.groundRelief
        guard relief.isEnabled else {
            return nil
        }
        return GroundReliefStore(device: device,
                                 settings: relief,
                                 flattening: settings.tiles.resolvedGroundFlattening,
                                 deepestTileZoom: settings.tiles.coverage.maximumZoomLevel,
                                 hillshade: hillshade)
    }

    /// The test seam: the terrain bytes from a closure, and a clock.
    /// `flattening` and `deepestTileZoom` are what the detail is matched
    /// to (`GroundReliefTerrainZooms`).
    init(device: MTLDevice,
         settings: ImmersiveMapSettings.TileSettings.GroundReliefSettings,
         flattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings = .init(),
         deepestTileZoom: Int = ImmersiveMapSettings.default.tiles.coverage.maximumZoomLevel,
         hillshade: ImmersiveMapHillshade = ImmersiveMapHillshade(),
         fetch: @escaping @Sendable (URL) async throws -> Fetched = GroundReliefStore.fetchOverHTTP,
         now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.device = device
        self.configuredExaggeration = settings.exaggeration
        self.appearZoom = settings.appearZoom
        self.collapseZoom = settings.collapseZoom
        self.transitionSeconds = max(settings.transitionSeconds, 0)
        self.zooms = GroundReliefTerrainZooms(relief: settings, flattening: flattening, deepestTileZoom: deepestTileZoom)
        self.hillshadeStyle = hillshade
        // Until the first frame: the relief as configured, standing.
        self.strengthScale = settings.exaggeration
        self.fromTileZoom = settings.tileZoom(deepestTileZoom: deepestTileZoom)
        self.cameraClearanceMetres = max(0, settings.cameraClearanceMetres)
        self.tileURLTemplate = settings.tileURLTemplate
        self.encoding = settings.encoding
        self.minimumSourceZoom = max(0, settings.minimumSourceZoom)
        let memoryBudgetInBytes = max(0, settings.memoryBudgetInBytes ?? settings.detail.defaultMemoryBudgetInBytes)
        self.terrains = LRUMemoryCache(costLimit: memoryBudgetInBytes)
        self.memoryBudgetInBytes = memoryBudgetInBytes
        self.maximumConcurrentLoads = max(1, settings.maximumConcurrentLoads)
        self.fetch = fetch
        self.now = now
        resolveHillshade()
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

    /// The zoom a ring of `zoom` reads its terrain at, by the relief's
    /// detail (`GroundReliefTerrainZooms.terrainZoom(forTargetZoom:)`).
    func terrainZoom(forTargetZoom zoom: Int) -> Int {
        zooms.terrainZoom(forTargetZoom: zoom)
    }

    /// The camera's terrain (`CameraTerrainFollow`): a pan keeps the eye's
    /// height by the zoom, and the zoom stops at the clearance over a
    /// ridge. The terrain is one map at every zoom, the terrain tiles of
    /// `cameraTerrainZoom` (`GroundReliefSettings.cameraTerrainZoom`), the
    /// map the frame's datum reads too (`GroundReliefCameraLift.datumMetres`).
    /// Read off the map of the frame's own tiles instead, a ray grazing a
    /// ridge answers in a loop: the map of one zoom says ridge, the arm
    /// shortens, the zoom crosses a level, the map of the next zoom,
    /// another grid with other heights, says plain, the arm lengthens, the
    /// zoom crosses back, and the camera shakes between the two every
    /// frame. One map, and the ridge is a ridge or not by the eye's place
    /// alone. The ground is drawn by its rings' own maps, which disagree
    /// with the camera's by their grids' difference, metres on a ridge. The
    /// terrain is read as drawn (`drawnMetres`), at the strength of each
    /// place. The camera over tiles coarser than the relief's zoom is over
    /// the plane, like the tiles.
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
                return self.drawnMetres(atNormalizedWorld: point, terrainZoom: self.cameraTerrainZoom)
            },
            clearanceMetres: Double(cameraClearanceMetres),
            globeRadiusScale: globeRadiusScale,
            sampleStepWorld: 1 / (Double(1 << cameraTerrainZoom) * Double(Self.nominalTerrainTileSize)))
    }

    /// The texels across a terrain tile: Mapterhorn's 512. The camera's
    /// march is stepped by it (`CameraTerrainFollow.sampleStepWorld`), and
    /// the relief's detail matches the terrain to the grids by it
    /// (`GroundReliefTerrainZooms`). A source of coarser tiles is marched
    /// finer than its texel and read a zoom finer than its heights need,
    /// which costs samples and tiles and nothing else.
    static let nominalTerrainTileSize = 512

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
        while true {
            if let terrain = terrains.value(forKey: source) {
                let placement = GroundRelief.placement(of: tile, in: source)
                return GroundRelief(terrain: terrain, origin: placement.origin, scale: placement.scale, strength: strengthScale)
            }
            guard orCoarser, source.z > 0, let parent = source.findParentTile(atZoom: source.z - 1) else {
                return nil
            }
            source = parent
        }
    }

    /// The relief of a ground tile drawn in a ring of `targetZoom`: the
    /// ring's terrain (`terrainZoom(forTargetZoom:)`), or the finest
    /// coarser one in (`relief(for:terrainZoom:)`).
    func relief(for tile: Tile, targetZoom: Int) -> GroundRelief? {
        relief(for: tile, terrainZoom: terrainZoom(forTargetZoom: targetZoom))
    }


    // MARK: - Demand

    /// The frame's terrain, nearest first (`GroundReliefDemand`): what the
    /// store loads, in that order, and keeps whatever the budget. A tile
    /// the source does not have is replaced by its ancestor, down to the
    /// source's floor. Called once a frame; an empty list wants nothing,
    /// which a frame off the terrain asks.
    func request(tiles: [Tile]) {
        lock.lock()
        var order: [Tile] = []
        order.reserveCapacity(tiles.count)
        var seen: Set<Tile> = []
        for tile in tiles {
            var source = tile
            while missingTiles.contains(source), source.z > minimumSourceZoom,
                  let parent = source.findParentTile(atZoom: source.z - 1) {
                source = parent
            }
            guard missingTiles.contains(source) == false, seen.insert(source).inserted else { continue }
            order.append(source)
        }
        wantedOrder = order
        wantedTiles = seen
        startWantedLoadsLocked()
        lock.unlock()
    }

    /// Starts the loads of the wanted tiles that are neither in nor on
    /// their way, nearest first, while slots are free. Called under `lock`.
    private func startWantedLoadsLocked() {
        let time = now()
        for tile in wantedOrder where activeLoads < maximumConcurrentLoads {
            guard terrains.peekValue(forKey: tile) == nil else { continue }
            switch statesByTile[tile] {
            case .loading:
                continue
            case .failed(let attempts, let retryAt):
                if time >= retryAt {
                    startLoad(tile, failedAttempts: attempts)
                }
            case nil:
                startLoad(tile, failedAttempts: 0)
            }
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

    /// How much taller than the terrain the ground under a point of the
    /// world is drawn this frame: zero off the terrain, nil while no
    /// terrain over the point is in.
    func strength(atNormalizedWorld point: SIMD2<Double>, terrainZoom zoom: Int) -> Float? {
        guard isActive else {
            return 0
        }
        guard relief(atNormalizedWorld: point, terrainZoom: zoom) != nil else {
            return nil
        }
        return strengthScale
    }

    /// The terrain under a point of the world as drawn: the datum plus
    /// the height over it at the frame's strength, in metres, so the
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

    /// The world units a metre of terrain rises by this frame, one for
    /// every tile and everything on them: the world units per metre at the
    /// latitude of the point the camera looks at (`setWorldScale`). The
    /// map stretches a metre by its latitude, and a tile that rose by its
    /// own latitude's would meet its north and south neighbours with the
    /// same heights at different rises, a seam the ground flickers along.
    /// One rise for the frame closes them, and the mountains keep their
    /// proportions where the camera looks, a far one to the north or the
    /// south a share of a percent off. The frame's strength is not in it
    /// (`GroundRelief.strength`).
    private(set) var worldUnitsPerMetre: Float = 0

    /// The frame's world units a metre of terrain rises by
    /// (`RenderFrameEngine`, once a frame, before anything of the frame
    /// reads the relief): at the latitude of `centerWorldMercator`, the
    /// point the camera looks at, on a map `renderMapSize` across.
    func setWorldScale(centerWorldMercator: SIMD2<Double>, renderMapSize: Double) {
        worldUnitsPerMetre = GroundReliefUniform.worldUnitsPerMetre(atNormalizedWorldY: centerWorldMercator.y,
                                                                    renderMapSize: renderMapSize)
    }

    /// Half floats' values.
    static func floats(halfBits bits: [UInt16]) -> [Float] {
        bits.map(GroundReliefTile.float(halfBits:))
    }

    /// What the store holds and does now, for the debug panel's relief tab.
    func statusSnapshot() -> GroundReliefStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let time = now()
        var tiles: [GroundReliefStatusSnapshot.TileStatus] = []
        var listed: Set<Tile> = []
        var wantedResident = 0
        func status(of tile: Tile, priority: Int?) -> GroundReliefStatusSnapshot.TileStatus {
            if let terrain = terrains.peekValue(forKey: tile) {
                return .init(tile: tile, state: .resident, priority: priority, bytes: terrain.costInBytes,
                             heightRange: terrain.heightRange, seconds: 0, attempts: 0)
            }
            switch statesByTile[tile] {
            case .loading(let failedAttempts):
                let started = loadStartedAt[tile] ?? time
                return .init(tile: tile, state: .loading, priority: priority, bytes: 0, heightRange: nil,
                             seconds: Int(max(0, time - started)), attempts: failedAttempts)
            case .failed(let attempts, let retryAt):
                return .init(tile: tile, state: .failed, priority: priority, bytes: 0, heightRange: nil,
                             seconds: Int(max(0, retryAt - time).rounded(.up)), attempts: attempts)
            case nil:
                return .init(tile: tile, state: .queued, priority: priority, bytes: 0, heightRange: nil,
                             seconds: 0, attempts: 0)
            }
        }
        for (priority, tile) in wantedOrder.enumerated() {
            let entry = status(of: tile, priority: priority)
            if entry.state == .resident { wantedResident += 1 }
            tiles.append(entry)
            listed.insert(tile)
        }
        let kept = (terrains.keys + statesByTile.keys).filter { listed.contains($0) == false }
        for tile in Set(kept).sorted(by: { ($0.z, $0.x, $0.y) < ($1.z, $1.x, $1.y) }) {
            tiles.append(status(of: tile, priority: nil))
        }
        let failed = statesByTile.values.reduce(0) { count, state in
            if case .failed = state { return count + 1 }
            return count
        }
        return GroundReliefStatusSnapshot(tiles: tiles,
                                          isActive: isActive,
                                          standingShare: standingShare,
                                          datumMetres: datumMetres,
                                          cameraTerrainZoom: cameraTerrainZoom,
                                          detail: zooms.detail,
                                          wantedCount: wantedOrder.count,
                                          wantedResidentCount: wantedResident,
                                          residentCount: terrains.count,
                                          residentBytes: terrains.totalCost,
                                          budgetBytes: memoryBudgetInBytes,
                                          loadingCount: activeLoads,
                                          maximumConcurrentLoads: maximumConcurrentLoads,
                                          failedCount: failed,
                                          missingCount: missingTiles.count)
    }

    /// Writes the welds queued since the last frame
    /// (`GroundReliefEdgeWeld`): the texels on the CPU, here on the main
    /// thread, where they are read, and the textures through a blit in a
    /// command buffer of the frame's queue, committed before the frame's
    /// own. Metal tracks the textures' hazards in a queue's order, so the
    /// blit lands after every frame before it has read them and before
    /// this frame reads them: no texture changes under a frame in flight.
    /// Called once a frame, before the frame's command buffer
    /// (`RenderFrameEngine`). Returns the blit's command buffer, nil with
    /// nothing to write.
    @discardableResult
    func applyPendingWelds(commandQueue: MTLCommandQueue) -> MTLCommandBuffer? {
        lock.lock()
        let writes = pendingWelds
        pendingWelds.removeAll()
        lock.unlock()
        guard writes.isEmpty == false else { return nil }

        var staging: [UInt16] = []
        staging.reserveCapacity(writes.reduce(0) { $0 + $1.values.count })
        var offsets: [Int] = []
        for write in writes {
            write.terrain.writeTexels(write.values, x: write.x, y: write.y, width: write.width, height: write.height)
            offsets.append(staging.count * MemoryLayout<UInt16>.stride)
            staging += write.values
        }
        guard let buffer = staging.withUnsafeBytes({ bytes in
                  device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
              }),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        commandBuffer.label = "GroundReliefEdgeWeld"
        for (write, offset) in zip(writes, offsets) {
            let rowBytes = write.width * MemoryLayout<UInt16>.stride
            blit.copy(from: buffer,
                      sourceOffset: offset,
                      sourceBytesPerRow: rowBytes,
                      sourceBytesPerImage: rowBytes * write.height,
                      sourceSize: MTLSize(width: write.width, height: write.height, depth: 1),
                      to: write.terrain.texture,
                      destinationSlice: 0,
                      destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: write.x, y: write.y, z: 0))
        }
        blit.endEncoding()
        commandBuffer.commit()
        // What is placed by the terrain on the CPU (the labels) is placed
        // again on the welded edges.
        lock.lock()
        version &+= 1
        lock.unlock()
        return commandBuffer
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
        loadStartedAt[tile] = now()
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
    /// CPU.
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
        return GroundReliefTile(texture: texture,
                                size: size,
                                halves: halves,
                                heightRange: min(lowest, highest) ... max(lowest, highest))
    }

    /// A load that ended: the terrain, or nil for a tile the source does
    /// not have (or cannot be read), which is then remembered as missing.
    private func finishLoad(_ tile: Tile, terrain: GroundReliefTile?, locked: Bool) {
        if locked == false {
            lock.lock()
        }
        statesByTile.removeValue(forKey: tile)
        loadStartedAt.removeValue(forKey: tile)
        activeLoads -= 1
        if let terrain {
            _ = terrains.setValue(terrain, forKey: tile, cost: terrain.costInBytes, protectedKeys: wantedTiles)
            version &+= 1
            // Its edges to the neighbours in, and theirs to it: written
            // with the frame, never into a texture a frame may be reading.
            pendingWelds += GroundReliefEdgeWeld.writes(for: tile, terrain: terrain) { [terrains] neighbour in
                terrains.peekValue(forKey: neighbour)
            }
        } else {
            missingTiles.insert(tile)
        }
        startWantedLoadsLocked()
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
        loadStartedAt.removeValue(forKey: tile)
        activeLoads -= 1
        startWantedLoadsLocked()
        lock.unlock()

        // The pause's end must draw a frame: on-demand rendering would
        // otherwise wait for a gesture.
        eventSink?.invalidate(.tileAvailable)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.eventSink?.invalidate(.tileAvailable)
        }
    }
}
