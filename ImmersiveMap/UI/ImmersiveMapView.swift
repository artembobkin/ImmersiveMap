// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import SwiftUI
import UIKit // For UIView

public struct ImmersiveMapView: View {
    var settings: ImmersiveMapSettings
    private var cameraPosition: ImmersiveMapCameraPosition?
    private var avatarsController: ImmersiveMapAvatarsController?
    private var cameraController: ImmersiveMapCameraController?
    private var cameraUIControls: CameraUIControls?
    private var selectionController: ImmersiveMapSelectionController?

    public init(settings: ImmersiveMapSettings = .default,
                avatarsController: ImmersiveMapAvatarsController? = nil,
                cameraPosition: ImmersiveMapCameraPosition? = nil,
                cameraController: ImmersiveMapCameraController? = nil,
                selectionController: ImmersiveMapSelectionController? = nil) {
        self.settings = settings
        self.avatarsController = avatarsController
        self.cameraPosition = cameraPosition
        self.cameraController = cameraController
        self.selectionController = selectionController
    }

    public var body: some View {
        let mapView = ImmersiveMapUIViewRepresentable(settings: settings,
                                                      avatarsController: avatarsController,
                                                      cameraPosition: cameraPosition,
                                                      cameraController: cameraController,
                                                      selectionController: selectionController)

        if let cameraUIControls, cameraUIControls.isEnabled, let cameraController {
            mapView.immersiveMapCameraControlsOverlay(
                camera: cameraController,
                initialCameraPosition: cameraPosition ?? Self.defaultCameraControlsPosition,
                maximumPitch: cameraUIControls.maximumPitch
            )
        } else {
            mapView
        }
    }
}

private struct ImmersiveMapUIViewRepresentable: UIViewRepresentable {
    let settings: ImmersiveMapSettings
    let avatarsController: ImmersiveMapAvatarsController?
    let cameraPosition: ImmersiveMapCameraPosition?
    let cameraController: ImmersiveMapCameraController?
    let selectionController: ImmersiveMapSelectionController?

    public func makeUIView(context: Context) -> ImmersiveMapUIView {
        let uiView = ImmersiveMapUIView(frame: .zero,
                                        settings: settings,
                                        avatarsController: avatarsController,
                                        cameraPosition: cameraPosition,
                                        cameraController: cameraController,
                                        selectionController: selectionController)
        return uiView
    }

    public func updateUIView(_ uiView: ImmersiveMapUIView, context: Context) {
        uiView.update(settings: settings,
                      avatarsController: avatarsController,
                      cameraController: cameraController,
                      selectionController: selectionController,
                      cameraPosition: cameraPosition)
    }

    public static func dismantleUIView(_ uiView: ImmersiveMapUIView, coordinator: ()) {
        uiView.dismantle()
    }
}

public extension ImmersiveMapView {

    func avatars(_ controller: ImmersiveMapAvatarsController?) -> ImmersiveMapView {
        var view = self
        view.avatarsController = controller
        return view
    }

    func camera(_ controller: ImmersiveMapCameraController?) -> ImmersiveMapView {
        var view = self
        view.cameraController = controller
        return view
    }

    func camera(_ controller: ImmersiveMapCameraController?,
                position: ImmersiveMapCameraPosition) -> ImmersiveMapView {
        var view = self
        view.cameraController = controller
        view.cameraPosition = position
        return view
    }

    func cameraPosition(_ position: ImmersiveMapCameraPosition?) -> ImmersiveMapView {
        var view = self
        view.cameraPosition = position
        return view
    }

    func cameraController(_ controller: ImmersiveMapCameraController?) -> ImmersiveMapView {
        var view = self
        view.cameraController = controller
        return view
    }

    func cameraController(_ controller: ImmersiveMapCameraController?,
                          position: ImmersiveMapCameraPosition) -> ImmersiveMapView {
        var view = self
        view.cameraController = controller
        view.cameraPosition = position
        return view
    }

    func enableCameraUIControls(_ isEnabled: Bool = true,
                                maximumPitch: Float = ImmersiveMapSettings.default.camera.maximumPitch) -> ImmersiveMapView {
        var view = self
        view.cameraUIControls = CameraUIControls(isEnabled: isEnabled, maximumPitch: maximumPitch)
        return view
    }

    func selection(_ controller: ImmersiveMapSelectionController?) -> ImmersiveMapView {
        var view = self
        view.selectionController = controller
        return view
    }

    public func renderLoopSettings(_ renderLoop: ImmersiveMapSettings.RenderLoopSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.renderLoopSettings(renderLoop)
        return view
    }

    public func cameraSettings(_ camera: ImmersiveMapSettings.CameraSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.cameraSettings(camera)
        return view
    }

    public func presentationSettings(_ presentation: ImmersiveMapSettings.PresentationSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.presentationSettings(presentation)
        return view
    }

    public func tileProvider<P: ImmersiveMapTileProvider>(_ tileProvider: P) -> ImmersiveMapView {
        self.tileProvider(AnyImmersiveMapTileProvider(tileProvider))
    }

    public func tileProvider(_ tileProvider: AnyImmersiveMapTileProvider) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.tileProvider(tileProvider)
        return view
    }

    public func mapStyle<S: ImmersiveMapMapStyle>(_ mapStyle: S) -> ImmersiveMapView {
        self.mapStyle(AnyImmersiveMapMapStyle(mapStyle))
    }

    public func mapStyle(_ mapStyle: AnyImmersiveMapMapStyle) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.mapStyle(mapStyle)
        return view
    }

    public func tileSettings(_ tiles: ImmersiveMapSettings.TileSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.tileSettings(tiles)
        return view
    }

    public func tileSettings(clearDiskCachesOnLaunch: Bool? = nil,
                             urlCacheEnabled: Bool? = nil,
                             preparedTileCacheEnabled: Bool? = nil,
                             preparedDiskTimeToLive: TimeInterval? = nil,
                             memoryCacheSizeInBytes: Int? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.tileSettings(
            clearDiskCachesOnLaunch: clearDiskCachesOnLaunch,
            urlCacheEnabled: urlCacheEnabled,
            preparedTileCacheEnabled: preparedTileCacheEnabled,
            preparedDiskTimeToLive: preparedDiskTimeToLive,
            memoryCacheSizeInBytes: memoryCacheSizeInBytes
        )
        return view
    }

    public func terrainSettings(_ terrain: ImmersiveMapSettings.TerrainSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.terrainSettings(terrain)
        return view
    }

    public func terrainSource(_ source: ImmersiveMapTerrainSource?) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.terrainSource(source)
        return view
    }

    public func terrainRendering(isEnabled: Bool = true,
                                 exaggeration: Float? = nil,
                                 maximumZoomLevel: Int? = nil,
                                 meshResolution: Int? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.terrainRendering(isEnabled: isEnabled,
                                                       exaggeration: exaggeration,
                                                       maximumZoomLevel: maximumZoomLevel,
                                                       meshResolution: meshResolution)
        return view
    }

    public func labelSettings(_ labels: ImmersiveMapSettings.LabelSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.labelSettings(labels)
        return view
    }

    public func sceneSettings(_ scene: ImmersiveMapSettings.SceneSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.sceneSettings(scene)
        return view
    }

    public func earthScene(isEnabled: Bool = true) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.earthScene(isEnabled: isEnabled)
        return view
    }

    public func nightLightsTileManifestURL(_ url: URL?) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.nightLightsTileManifestURL(url)
        return view
    }

    public func styleSettings(_ style: ImmersiveMapSettings.StyleSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.styleSettings(style)
        return view
    }

    public func avatarSettings(_ avatars: ImmersiveMapSettings.AvatarSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.avatarSettings(avatars)
        return view
    }

    public func avatarSettings(size: ImmersiveMapSettings.AvatarSettings.Size? = nil,
                               sizeScale: Float? = nil,
                               singleLiftScale: Float? = nil,
                               secondaryScale: Float? = nil,
                               atlasSizePx: Int? = nil,
                               atlasPagesMax: Int? = nil,
                               borderWidthPx: Float? = nil,
                               borderColor: SIMD4<Float>? = nil,
                               beamWidthPx: Float? = nil,
                               beamColor: SIMD4<Float>? = nil,
                               collisionPaddingPx: Float? = nil,
                               petalsThreshold: UInt32? = nil,
                               petalSpacingPx: Float? = nil,
                               maxOffsetPx: Float? = nil,
                               clusterIterations: Int? = nil,
                               repulsionK: Float? = nil,
                               springK: Float? = nil,
                               smoothing: Float? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.avatarSettings(size: size,
                                                     sizeScale: sizeScale,
                                                     singleLiftScale: singleLiftScale,
                                                     secondaryScale: secondaryScale,
                                                     atlasSizePx: atlasSizePx,
                                                     atlasPagesMax: atlasPagesMax,
                                                     borderWidthPx: borderWidthPx,
                                                     borderColor: borderColor,
                                                     beamWidthPx: beamWidthPx,
                                                     beamColor: beamColor,
                                                     collisionPaddingPx: collisionPaddingPx,
                                                     petalsThreshold: petalsThreshold,
                                                     petalSpacingPx: petalSpacingPx,
                                                     maxOffsetPx: maxOffsetPx,
                                                     clusterIterations: clusterIterations,
                                                     repulsionK: repulsionK,
                                                     springK: springK,
                                                     smoothing: smoothing)
        return view
    }

    public func attributionSettings(_ attribution: ImmersiveMapSettings.AttributionSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.attributionSettings(attribution)
        return view
    }

    public func postProcessingSettings(_ postProcessing: ImmersiveMapSettings.PostProcessingSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.postProcessingSettings(postProcessing)
        return view
    }

    public func debugSettings(_ debug: ImmersiveMapSettings.DebugSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.debugSettings(debug)
        return view
    }

    public func debugPanel(_ isEnabled: Bool = true) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.debugPanel(isEnabled)
        return view
    }

}

private extension ImmersiveMapView {
    struct CameraUIControls {
        let isEnabled: Bool
        let maximumPitch: Float
    }

    static var defaultCameraControlsPosition: ImmersiveMapCameraPosition {
        ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                   longitudeDegrees: 0,
                                   zoom: 0)
    }
}

#endif
