// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import simd

/// The ground relief's state across frames, which the frame engine sets
/// once a frame and the frame reads as a value (`frame`,
/// `GroundReliefFrame`): how far the relief has risen and its rise and
/// collapse over the zooms, the world units a metre rises by, the light
/// the slopes are shaded by, the darkening where the terrain hides the
/// sky, whether the mountains cast shadows, whether the frame is on the
/// terrain and the datum it is drawn from. The terrain tiles are the
/// store's (`store`), which this state tells only the frame's ring bands
/// and the key the tiles' occlusion is computed with.
///
/// It is all the frame engine knows of the relief. The engine sets it in
/// the frame's order (`RenderFrameEngine`): the frame's start first
/// (`beginFrame`), the zoom (`setFrame`), then the world scale, the light,
/// the occlusion and the shadows, then the bands and whether the frame is
/// on the terrain, and last the datum, which is read off the terrain as
/// the frame now draws it. Everything after reads `frame`.
///
/// Main thread only, as the frame engine is.
final class GroundReliefFrameState {
    /// The terrain tiles.
    let store: GroundReliefStore

    private let configuredExaggeration: Float
    private let appearZoom: Double
    private let collapseZoom: Double
    /// Whether the relief collapses where the source has no terrain at the
    /// zoom the near ring reads it (`GroundReliefSettings
    /// .collapsesWhereTerrainIsMissing`).
    private let collapsesWhereTerrainIsMissing: Bool
    /// The tileset's deepest zoom, which bounds the near ring's tile zoom
    /// (`TileCoverageZoomPolicy`).
    private let deepestTileZoom: Int
    private let transitionSeconds: TimeInterval
    /// The frame's tile zoom the ground rises from, the tile zoom of
    /// `GroundReliefSettings.appearZoom` (`tileZoom(deepestTileZoom:)`), the
    /// zoom the ground is flattened from too: a frame of coarser tiles, and
    /// whatever stands on them, lies on the plane, and so does the camera
    /// over such a frame.
    let fromTileZoom: Int
    /// The least height the camera keeps over the relief under it.
    let cameraClearanceMetres: Float

    /// How the slopes are shaded (`ImmersiveMapHillshade`, the style's).
    private let hillshadeStyle: ImmersiveMapHillshade
    /// How the ground is darkened where the terrain hides the sky
    /// (`ImmersiveMapTerrainOcclusion`): the style's, or the debug panel's
    /// over it (`setOcclusion`).
    private let occlusionStyle: ImmersiveMapTerrainOcclusion
    private var occlusion: ImmersiveMapTerrainOcclusion
    /// Whether the frame draws the occlusion alone, in grey, in place of
    /// the map (the debug panel's view of it).
    private var occlusionDebugView = false

    /// How much of the relief stands: 1 standing, 0 lying in the plane,
    /// between them on its way over `transitionSeconds`, up when the
    /// zoom entered the relief's zooms (`GroundReliefSettings.appearZoom`
    /// to `collapseZoom`) and down when it left them. Never a function of
    /// the zoom itself: a relief scaled with the zoom breathes with every
    /// drag over the terrain, whose slopes move the zoom.
    private(set) var standingShare: Float = 1
    /// The standing share eased as the relief rises and collapses
    /// (`setFrame`): what the strength, the hillshade and the occlusion
    /// scale by.
    private var risenShare: Float = 1
    /// How much taller than the terrain the ground is drawn this frame
    /// (`setFrame`): the configured exaggeration times the risen share, the
    /// same everywhere, so nothing moves with the camera but the zoom's
    /// crossing of a threshold.
    private var strength: Float
    /// The frame's zoom (`setFrame`), which the hillshade's fade is read at.
    private var frameZoom: Double = 0
    /// Whether the source has no terrain at the zoom the near ring reads
    /// it under the point the camera looks at this frame (`setFrame`,
    /// `GroundReliefStore.ringTerrainIsMissing`): the relief lies in the
    /// plane there as past `collapseZoom`.
    private var terrainIsMissing = false
    private var lightDirection = ImmersiveMapSettings.SceneLightSettings().direction
    private var cameraEye = SIMD3<Float>(0, 0, 1)
    private var hillshadeFade: GroundReliefHillshade.Fade?
    private var hillshadeAmounts: GroundReliefHillshade.Amounts?
    /// The shading of the slopes this frame: the scene's light and the
    /// style's intensity at the share of the relief that has risen, so the
    /// shading rises and collapses with the relief.
    private var hillshade: GroundReliefHillshade = .none
    /// Whether the mountains may cast their shadows
    /// (`GroundReliefSettings.castsShadows`, the debug panel's over it).
    private var castsShadowsEnabled = false
    /// The world units a metre of terrain rises by this frame
    /// (`setWorldScale`).
    private var worldUnitsPerMetre: Float = 0
    /// Whether the frame is on the terrain (`setActive`).
    private(set) var isActive = true
    /// The frame's datum (`setDatum`).
    private var datumMetres: Float = 0

    /// The relief of a map's settings, its store loading the terrain from
    /// the settings' URL template: nil while the relief is off. `hillshade`
    /// and `occlusion` are the style's (`MapStyleRuntime`).
    static func make(settings: ImmersiveMapSettings,
                     hillshade: ImmersiveMapHillshade,
                     occlusion: ImmersiveMapTerrainOcclusion = ImmersiveMapTerrainOcclusion(),
                     device: MTLDevice) -> GroundReliefFrameState? {
        let relief = settings.tiles.groundRelief
        guard relief.isEnabled else {
            return nil
        }
        let store = GroundReliefStore(device: device,
                                      settings: relief,
                                      source: GroundReliefURLTerrainSource(settings: relief),
                                      occlusionKey: GroundReliefOcclusion.Key(style: occlusion))
        return GroundReliefFrameState(store: store,
                                      settings: relief,
                                      deepestTileZoom: settings.tiles.coverage.maximumZoomLevel,
                                      hillshade: hillshade,
                                      occlusion: occlusion)
    }

    /// `deepestTileZoom` is the tileset's deepest zoom, which with the
    /// relief's collapse bounds the tiles the relief is drawn on
    /// (`fromTileZoom`). The store's tiles are computed with the
    /// occlusion's key from here on.
    init(store: GroundReliefStore,
         settings: ImmersiveMapSettings.TileSettings.GroundReliefSettings,
         deepestTileZoom: Int = ImmersiveMapSettings.default.tiles.coverage.maximumZoomLevel,
         hillshade: ImmersiveMapHillshade = ImmersiveMapHillshade(),
         occlusion: ImmersiveMapTerrainOcclusion = ImmersiveMapTerrainOcclusion()) {
        self.store = store
        self.configuredExaggeration = settings.exaggeration
        self.appearZoom = settings.appearZoom
        self.collapseZoom = settings.collapseZoom
        self.collapsesWhereTerrainIsMissing = settings.collapsesWhereTerrainIsMissing
        self.deepestTileZoom = deepestTileZoom
        self.transitionSeconds = max(settings.transitionSeconds, 0)
        self.fromTileZoom = settings.tileZoom(deepestTileZoom: deepestTileZoom)
        self.cameraClearanceMetres = max(0, settings.cameraClearanceMetres)
        self.hillshadeStyle = hillshade
        self.occlusionStyle = occlusion
        self.occlusion = occlusion
        // Until the first frame: the relief as configured, standing.
        self.strength = settings.exaggeration
        store.setOcclusionKey(GroundReliefOcclusion.Key(style: occlusion))
        resolveHillshade()
    }

    /// The relief as the frame draws it, settled by the setters before it.
    var frame: GroundReliefFrame {
        GroundReliefFrame(store: store,
                          isActive: isActive,
                          strength: strength,
                          standingShare: standingShare,
                          datumMetres: datumMetres,
                          worldUnitsPerMetre: worldUnitsPerMetre,
                          hillshade: hillshade,
                          occlusionUniform: occlusionUniform,
                          castsShadows: castsShadowsEnabled && isActive && strength > 0,
                          fromTileZoom: fromTileZoom,
                          collapseTileZoom: collapseTileZoom)
    }

    // MARK: - The frame's start and end

    /// The frame's start (`RenderFrameEngine`, once a frame, before the
    /// frame's command buffer): the terrain tiles' edges welded to their
    /// neighbours' since the last frame are written, on the frame's queue
    /// (`GroundReliefStore.applyPendingWelds`). Returns the welds' command
    /// buffer, nil with nothing to write.
    @discardableResult
    func beginFrame(commandQueue: MTLCommandQueue) -> MTLCommandBuffer? {
        store.applyPendingWelds(commandQueue: commandQueue)
    }

    /// The wanted terrain tiles still on their way
    /// (`GroundReliefStore.pendingWantedCount`): what a still capture waits
    /// for (`FrameDiagnostics.Counter.pendingTerrainTiles`).
    var pendingTerrainTileCount: Int {
        store.pendingWantedCount
    }

    // MARK: - The rise and the collapse

    /// The frame's zoom (`RenderFrameEngine`, once a frame, before
    /// anything of the frame reads the relief): the zoom held through a
    /// drag, the camera's otherwise. The relief moves toward standing
    /// when the zoom is within its zooms and toward the plane when it is
    /// not, by `deltaTime` over `transitionSeconds`, or at once with
    /// `snap`. Without a `deltaTime` it is settled where the zoom puts
    /// it.
    ///
    /// `centerWorldMercator` is the point the camera looks at: where the
    /// source has no terrain at the zoom the near ring reads it under
    /// that point (`GroundReliefSettings.collapsesWhereTerrainIsMissing`),
    /// the relief moves toward the plane as past `collapseZoom`. Nil reads
    /// no terrain, and the zoom alone decides.
    func setFrame(zoom: Double,
                  centerWorldMercator: SIMD2<Double>? = nil,
                  deltaTime: TimeInterval? = nil,
                  snap: Bool = false) {
        frameZoom = zoom
        if collapsesWhereTerrainIsMissing, let centerWorldMercator {
            let tileZoom = TileCoverageZoomPolicy.resolve(cameraZoom: zoom,
                                                          renderSurfaceMode: .flat,
                                                          maximumZoomLevel: deepestTileZoom).baseZoom
            terrainIsMissing = store.ringTerrainIsMissing(under: centerWorldMercator, targetZoom: tileZoom)
        } else {
            terrainIsMissing = false
        }
        let target: Float = stands(atZoom: zoom) ? 1 : 0
        if let deltaTime, snap == false, transitionSeconds > 0 {
            let step = Float(max(deltaTime, 0) / transitionSeconds)
            standingShare = target > standingShare ? min(standingShare + step, target) : max(standingShare - step, target)
        } else {
            standingShare = target
        }
        let eased = standingShare * standingShare * (3 - 2 * standingShare)
        risenShare = eased
        strength = configuredExaggeration * eased
        resolveHillshade()
    }

    /// Whether the rise or the collapse is under way this frame: the
    /// frames keep coming while it is (`RenderFrameEngine`).
    var isTransitioning: Bool { standingShare > 0 && standingShare < 1 }

    /// Whether the relief stands at a zoom: from `appearZoom` up to
    /// `collapseZoom`, and not where the frame found the source without
    /// terrain for the near ring (`setFrame`, `terrainIsMissing`).
    func stands(atZoom zoom: Double) -> Bool {
        zoom >= appearZoom && zoom < collapseZoom && terrainIsMissing == false
    }

    /// Whether anything of the relief stands at a zoom (the zoom held
    /// through a drag, the camera's otherwise): within its zooms, or
    /// still on its way into the plane.
    func isVisible(atZoom zoom: Double) -> Bool {
        stands(atZoom: zoom) || standingShare > 0
    }

    /// The tile zoom of the collapse zoom (`GroundReliefSettings
    /// .collapseZoom`): the deepest tile zoom whose frames the relief
    /// stands on, and the deepest the terrain is asked for while the
    /// relief lies collapsed past it (`TileWorkingSetSubsystem`).
    var collapseTileZoom: Int {
        collapseZoom.isFinite ? Int(max(collapseZoom, 0).rounded(.down)) : Int.max
    }

    // MARK: - The frame's world and light

    /// The frame's world units a metre of terrain rises by
    /// (`RenderFrameEngine`, once a frame, before anything of the frame
    /// reads the relief): at the latitude of `centerWorldMercator`, the
    /// point the camera looks at, on a map `renderMapSize` across. One for
    /// every tile and everything on them: the map stretches a metre by its
    /// latitude, and a tile that rose by its own latitude's would meet its
    /// north and south neighbours with the same heights at different
    /// rises, a seam the ground flickers along. One rise for the frame
    /// closes them, and the mountains keep their proportions where the
    /// camera looks, a far one to the north or the south a share of a
    /// percent off.
    func setWorldScale(centerWorldMercator: SIMD2<Double>, renderMapSize: Double) {
        worldUnitsPerMetre = GroundReliefUniform.worldUnitsPerMetre(atNormalizedWorldY: centerWorldMercator.y,
                                                                    renderMapSize: renderMapSize)
        // The hillshade's fade is metres in these units.
        resolveHillshade()
    }

    /// The scene's light this frame (`SceneLightSettings.direction`, toward
    /// the light, `RenderFrameEngine`), which the slopes are shaded by, and
    /// the eye they fade with the distance from, in metres at the frame's
    /// zoom (`setFrame`) and rise (`setWorldScale`). `fade` replaces the
    /// style's fade and `amounts` its amounts (the debug panel's), nil
    /// keeps the style's.
    func setLight(direction: SIMD3<Float>,
                  cameraEye: SIMD3<Float>,
                  fade: GroundReliefHillshade.Fade? = nil,
                  amounts: GroundReliefHillshade.Amounts? = nil) {
        lightDirection = direction
        self.cameraEye = cameraEye
        hillshadeFade = fade
        hillshadeAmounts = amounts
        resolveHillshade()
    }

    private func resolveHillshade() {
        hillshade = GroundReliefHillshade.resolve(style: hillshadeStyle,
                                                  lightDirection: lightDirection,
                                                  risenShare: risenShare,
                                                  cameraEye: cameraEye,
                                                  zoom: frameZoom,
                                                  unitsPerMetre: worldUnitsPerMetre,
                                                  fade: hillshadeFade,
                                                  amounts: hillshadeAmounts)
    }

    /// How the ground is darkened this frame (`RenderFrameEngine`, once a
    /// frame): `style` replaces the map style's (the debug panel's), nil
    /// keeps it. `debugView` draws the occlusion alone. A change to what
    /// the tiles' occlusion is computed with (the radius, the directions,
    /// the resolution, on or off) computes every tile in again
    /// (`GroundReliefStore.setOcclusionKey`).
    func setOcclusion(_ style: ImmersiveMapTerrainOcclusion?, debugView: Bool) {
        let resolved = style ?? occlusionStyle
        occlusionDebugView = debugView
        guard resolved != occlusion else { return }
        occlusion = resolved
        store.setOcclusionKey(GroundReliefOcclusion.Key(style: resolved))
    }

    /// The strength the fills darken by this frame and whether they draw
    /// the occlusion alone: the style's strength times how far the relief
    /// has risen, so the darkening rises and collapses with the mountains.
    private var occlusionUniform: SIMD4<Float> {
        let strength = occlusion.isEnabled ? min(max(occlusion.strength, 0), 1) * risenShare : 0
        return SIMD4<Float>(strength, occlusionDebugView ? 1 : 0, 0, 0)
    }

    /// Whether the mountains may cast their shadows this frame
    /// (`RenderFrameEngine`, once a frame).
    func setCastsShadows(_ isEnabled: Bool) {
        castsShadowsEnabled = isEnabled
    }

    // MARK: - On the terrain

    /// The frame's ring bands (`VisibleContentState.flatRingBands`,
    /// `RenderFrameEngine`, once a frame, before anything of the frame
    /// reads the relief), which the store reads its rings' terrain by
    /// (`GroundReliefStore.setBands`).
    func setBands(_ bands: [FlatRingBand]) {
        store.setBands(bands)
    }

    /// Whether the frame is on the terrain (`RenderFrameEngine`, once a
    /// frame): the flat map with tiles of the relief's zoom or deeper,
    /// at a zoom within the relief's zooms or on its way out of them
    /// (`isVisible(atZoom:)`). On, every tile of the frame rises,
    /// however coarse, so no tile left on the plane cuts through the
    /// valleys under the point looked at.
    func setActive(_ isActive: Bool) {
        self.isActive = isActive
    }

    /// The frame's datum (`RenderFrameEngine`, once a frame,
    /// `GroundReliefCameraLift.datumMetres`). The ground, the buildings and
    /// the labels rise by their terrain's height over it, so the point the
    /// camera looks at lies at the world's origin, on the ground, and the
    /// camera's pose, made for the plane, holds unchanged. Kept while the
    /// terrain under the point is on its way.
    func setDatum(metres: Float) {
        datumMetres = metres
    }

    // MARK: - The camera

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
    /// terrain is read as drawn (`GroundReliefFrame.drawnMetres`), at the
    /// strength of each place, off the last frame's relief. The camera over
    /// tiles coarser than the relief's zoom is over the plane, like the
    /// tiles.
    func makeTerrainFollow(tileSettings: ImmersiveMapSettings.TileSettings,
                           globeRadiusScale: Double,
                           cameraZoom: @escaping () -> Double) -> CameraTerrainFollow {
        let cameraTerrainZoom = store.cameraTerrainZoom
        return CameraTerrainFollow(
            terrainMetres: { [weak self] point in
                guard let self else { return nil }
                let tileZoom = tileSettings.resolvedCoverageZoomLevel(forCameraZoom: cameraZoom())
                guard tileZoom >= self.fromTileZoom else {
                    return 0
                }
                return self.frame.drawnMetres(atNormalizedWorld: point, terrainZoom: cameraTerrainZoom)
            },
            clearanceMetres: Double(cameraClearanceMetres),
            globeRadiusScale: globeRadiusScale,
            sampleStepWorld: 1 / (Double(1 << cameraTerrainZoom) * Double(GroundReliefStore.nominalTerrainTileSize)))
    }
}
