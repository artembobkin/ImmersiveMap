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
/// tile's own or an ancestor's.
struct GroundRelief {
    /// The terrain tile's heights (`GroundReliefTile`), the texture the
    /// vertex stages sample and the same numbers the CPU reads.
    let terrain: GroundReliefTile
    /// The ground tile's north-west corner in the texture, in 0...1.
    let origin: SIMD2<Float>
    /// The ground tile's side in the texture, in 0...1: 1 for the tile's
    /// own terrain, a half for its parent's.
    let scale: Float

    var texture: MTLTexture { terrain.texture }

    /// The terrain's height in metres under a point of the ground tile, in
    /// the tile's uv (v from the north edge), bilinear between the texels
    /// around it, as the vertex stage samples it.
    func metres(atTileUV uv: SIMD2<Float>) -> Float {
        terrain.metres(atTextureUV: origin + simd_clamp(uv, SIMD2<Float>(repeating: 0), SIMD2<Float>(repeating: 1)) * scale)
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

    init(texture: MTLTexture, size: Int, halves: [UInt16], heightRange: ClosedRange<Float>) {
        self.texture = texture
        self.size = size
        self.halves = halves
        self.heightRange = heightRange
    }

    var costInBytes: Int {
        texture.allocatedSize + halves.count * MemoryLayout<UInt16>.stride
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

    /// How much taller than the terrain the ground is drawn this frame:
    /// the configured exaggeration scaled by the zoom fade at the frame's
    /// camera zoom (`setFrame`), down to zero where the fade ends and the
    /// ground lies on the plane. Everything that rises with the terrain
    /// reads it, the ground, the buildings, the labels, the datum and the
    /// camera, so a zoom scales the whole relief as one about the point
    /// the camera looks at, which stays on the ground throughout.
    private(set) var exaggeration: Float
    /// The terrain's rise and fall within the window around the point the
    /// camera looks at this frame, in metres before the exaggeration
    /// (`GroundReliefSettings.reliefWindowMetres`): what the frame's fade
    /// is read off, flat ground's or the mountains'. Kept from the last
    /// frame that could read the terrain.
    private(set) var reliefRangeMetres: Float = 0
    private let configuredExaggeration: Float
    private let flatZoomFade: ImmersiveMapZoomFade
    private let mountainZoomFade: ImmersiveMapZoomFade
    private let reliefWindowMetres: Float
    private let flatReliefMetres: Float
    private let mountainReliefMetres: Float

    /// The frame's camera (`RenderFrameEngine`, once a frame, before
    /// anything of the frame reads the relief): the terrain's rise and
    /// fall around the point it looks at, read at `tileZoom`, the zoom of
    /// the frame's tiles, on a grid of 9 by 9 points over the window,
    /// bilinear in the terrain and so continuous in the point, and from
    /// it and the camera zoom the exaggeration. Points whose terrain is
    /// not in are left out, and a window with none keeps the last range.
    func setFrame(cameraZoom: Double, centerWorldMercator: SIMD2<Double>, tileZoom: Int) {
        if isActive, tileZoom >= fromTileZoom {
            let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: centerWorldMercator.y)
            let metresPerWorld = ImmersiveMapProjection.earthCircumferenceMeters * max(cos(latitude), 1e-6)
            let halfWindow = Double(reliefWindowMetres) * 0.5 / metresPerWorld
            var lowest = Float.greatestFiniteMagnitude
            var highest = -Float.greatestFiniteMagnitude
            for row in -4 ... 4 {
                for column in -4 ... 4 {
                    let point = centerWorldMercator + SIMD2<Double>(Double(column), Double(row)) * (halfWindow / 4)
                    guard let metres = elevation(atNormalizedWorld: point,
                                                 terrainZoom: Self.terrainZoom(forTargetZoom: tileZoom)) else { continue }
                    lowest = min(lowest, metres)
                    highest = max(highest, metres)
                }
            }
            if lowest <= highest {
                reliefRangeMetres = highest - lowest
            }
        }
        let span = max(mountainReliefMetres - flatReliefMetres, 1)
        let t = min(max((reliefRangeMetres - flatReliefMetres) / span, 0), 1)
        let mountainShare = t * t * (3 - 2 * t)
        let alpha = flatZoomFade.alpha(atZoom: cameraZoom) * (1 - mountainShare)
            + mountainZoomFade.alpha(atZoom: cameraZoom) * mountainShare
        exaggeration = configuredExaggeration * alpha
    }
    /// The frame's tile zoom the ground rises from
    /// (`GroundReliefSettings.fromTileZoom`): a frame of coarser tiles,
    /// and whatever stands on them, lies on the plane, and so does the
    /// camera over such a frame.
    let fromTileZoom: Int
    /// Whether the frame is on the terrain (`RenderFrameEngine`, once a
    /// frame): the flat map with tiles of the relief's zoom or deeper.
    /// Off, every tile and whatever stands on it lies on the plane. On,
    /// every tile of the frame rises, however coarse, so no tile left on
    /// the plane cuts through the valleys under the point looked at.
    private(set) var isActive = true
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
        self.flatZoomFade = settings.flatZoomFade
        self.mountainZoomFade = settings.mountainZoomFade
        self.reliefWindowMetres = max(settings.reliefWindowMetres, 1)
        self.flatReliefMetres = max(settings.flatReliefMetres, 0)
        self.mountainReliefMetres = max(settings.mountainReliefMetres, settings.flatReliefMetres)
        self.exaggeration = settings.exaggeration
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
    /// The camera over tiles coarser than the relief's zoom is over the
    /// plane, like the tiles.
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
                return self.elevation(atNormalizedWorld: point, terrainZoom: Self.terrainZoom(forTargetZoom: tileZoom))
                    .map { $0 * self.exaggeration }
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
                return GroundRelief(terrain: terrain, origin: placement.origin, scale: placement.scale)
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

    /// The terrain's height in metres under a point of the world
    /// (normalized world mercator), from the terrain tile of `terrainZoom`
    /// that holds it: bilinear between the four texels around it, as the
    /// vertex stage samples it. From the finest coarser terrain in while
    /// that one is on its way, nil while no terrain over the point is in,
    /// and zero while the frame is off the terrain (`isActive`), on the
    /// plane.
    func elevation(atNormalizedWorld point: SIMD2<Double>, terrainZoom zoom: Int) -> Float? {
        guard isActive else {
            return 0
        }
        let tilesCount = Double(1 << max(0, zoom))
        let wrappedX = ImmersiveMapProjection.wrapNormalizedWorldX(point.x)
        let clampedY = ImmersiveMapProjection.clampNormalizedWorldY(point.y)
        let column = min(Int(wrappedX * tilesCount), Int(tilesCount) - 1)
        let row = min(Int(clampedY * tilesCount), Int(tilesCount) - 1)
        guard let relief = relief(for: Tile(x: column, y: row, z: zoom), terrainZoom: zoom) else {
            return nil
        }
        let inTile = SIMD2<Float>(Float(wrappedX * tilesCount - Double(column)), Float(clampedY * tilesCount - Double(row)))
        return relief.metres(atTileUV: inTile)
    }

    /// The world units a metre of this terrain rises by over a tile: the
    /// world units per metre at the tile's latitude, times the
    /// exaggeration.
    func worldUnitsPerMetre(over tile: Tile, renderMapSize: Double) -> Float {
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: (Double(tile.y) + 0.5) / Double(1 << tile.z))
        let unitsPerMetre = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: latitude, renderMapSize: renderMapSize)
        return Float(unitsPerMetre) * exaggeration
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
                    let terrain = try self.makeTerrain(GroundReliefDecoder.decode(data, encoding: self.encoding))
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

    /// The heights as half floats, in a texture for the GPU and on the CPU.
    private func makeTerrain(_ heights: GroundReliefHeights) throws -> GroundReliefTile {
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
        return GroundReliefTile(texture: texture, size: size, halves: halves, heightRange: min(lowest, highest) ... max(lowest, highest))
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
