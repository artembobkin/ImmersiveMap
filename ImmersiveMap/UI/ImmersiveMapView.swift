// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct ImmersiveMapView: View {
    var settings: ImmersiveMapSettings
    private var cameraPosition: ImmersiveMapCameraPosition?
    private var avatarsController: ImmersiveMapAvatarsController?
    private var cameraController: ImmersiveMapCameraController?
    private var cameraUIControls: CameraUIControls?
    private var selectionController: ImmersiveMapSelectionController?
    private var markerTapAction: ((ImmersiveMapMarkerTapEvent) -> Void)?

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
                                                      selectionController: selectionController,
                                                      markerTapAction: markerTapAction)

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

#if canImport(UIKit)
private struct ImmersiveMapUIViewRepresentable: UIViewRepresentable {
    let settings: ImmersiveMapSettings
    let avatarsController: ImmersiveMapAvatarsController?
    let cameraPosition: ImmersiveMapCameraPosition?
    let cameraController: ImmersiveMapCameraController?
    let selectionController: ImmersiveMapSelectionController?
    let markerTapAction: ((ImmersiveMapMarkerTapEvent) -> Void)?

    public func makeUIView(context: Context) -> ImmersiveMapUIView {
        let uiView = ImmersiveMapUIView(frame: .zero,
                                        settings: settings,
                                        avatarsController: avatarsController,
                                        cameraPosition: cameraPosition,
                                        cameraController: cameraController,
                                        selectionController: selectionController,
                                        markerTapAction: markerTapAction)
        return uiView
    }

    public func updateUIView(_ uiView: ImmersiveMapUIView, context: Context) {
        uiView.update(settings: settings,
                      avatarsController: avatarsController,
                      cameraController: cameraController,
                      selectionController: selectionController,
                      markerTapAction: markerTapAction,
                      cameraPosition: cameraPosition)
    }

    public static func dismantleUIView(_ uiView: ImmersiveMapUIView, coordinator: ()) {
        uiView.dismantle()
    }
}
#elseif canImport(AppKit)
private struct ImmersiveMapUIViewRepresentable: NSViewRepresentable {
    let settings: ImmersiveMapSettings
    let avatarsController: ImmersiveMapAvatarsController?
    let cameraPosition: ImmersiveMapCameraPosition?
    let cameraController: ImmersiveMapCameraController?
    let selectionController: ImmersiveMapSelectionController?
    let markerTapAction: ((ImmersiveMapMarkerTapEvent) -> Void)?

    public func makeNSView(context: Context) -> ImmersiveMapNSView {
        let nsView = ImmersiveMapNSView(frame: .zero,
                                        settings: settings,
                                        avatarsController: avatarsController,
                                        cameraPosition: cameraPosition,
                                        cameraController: cameraController,
                                        selectionController: selectionController,
                                        markerTapAction: markerTapAction)
        return nsView
    }

    public func updateNSView(_ nsView: ImmersiveMapNSView, context: Context) {
        nsView.update(settings: settings,
                      avatarsController: avatarsController,
                      cameraController: cameraController,
                      selectionController: selectionController,
                      markerTapAction: markerTapAction,
                      cameraPosition: cameraPosition)
    }

    public static func dismantleNSView(_ nsView: ImmersiveMapNSView, coordinator: ()) {
        nsView.dismantle()
    }
}
#endif

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

    /// Вызывает `action` на каждое нажатие по avatar marker.
    /// Работает без ``ImmersiveMapSelectionController``: событие приходит и когда
    /// selection не используется, и повторно при tap по уже выбранному маркеру.
    func onMarkerTap(_ action: @escaping (ImmersiveMapMarkerTapEvent) -> Void) -> ImmersiveMapView {
        var view = self
        view.markerTapAction = action
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
        tileSettings(clearDiskCachesOnLaunch: clearDiskCachesOnLaunch,
                     urlCacheEnabled: urlCacheEnabled,
                     preparedTileCacheEnabled: preparedTileCacheEnabled,
                     preparedDiskTimeToLive: preparedDiskTimeToLive,
                     preparedDiskCacheSizeInBytes: nil,
                     memoryCacheSizeInBytes: memoryCacheSizeInBytes)
    }

    public func tileSettings(clearDiskCachesOnLaunch: Bool? = nil,
                             urlCacheEnabled: Bool? = nil,
                             preparedTileCacheEnabled: Bool? = nil,
                             preparedDiskTimeToLive: TimeInterval? = nil,
                             preparedDiskCacheSizeInBytes: Int?,
                             memoryCacheSizeInBytes: Int? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.tileSettings(
            clearDiskCachesOnLaunch: clearDiskCachesOnLaunch,
            urlCacheEnabled: urlCacheEnabled,
            preparedTileCacheEnabled: preparedTileCacheEnabled,
            preparedDiskTimeToLive: preparedDiskTimeToLive,
            preparedDiskCacheSizeInBytes: preparedDiskCacheSizeInBytes,
            memoryCacheSizeInBytes: memoryCacheSizeInBytes
        )
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

    public func styleSettings(_ style: ImmersiveMapSettings.StyleSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.styleSettings(style)
        return view
    }

    /// Режим отображения выдавленных 3D-зданий в flat-презентации:
    /// `.translucent` - полупрозрачные (по умолчанию), `.solid` - непрозрачные,
    /// `.solidAtHighZoom` - плавный переход от полупрозрачных к непрозрачным
    /// в диапазоне зумов (по умолчанию 17...18).
    public func buildingExtrusionMode(_ mode: ImmersiveMapSettings.StyleSettings.BuildingExtrusionMode) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.buildingExtrusionMode(mode)
        return view
    }

    public func avatarSettings(_ avatars: ImmersiveMapSettings.AvatarSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.avatarSettings(avatars)
        return view
    }

    public func avatarSettings(size: ImmersiveMapSettings.AvatarSettings.Size? = nil,
                               sizeScale: Float? = nil,
                               compressedScale: Float? = nil,
                               atlasSizePx: Int? = nil,
                               atlasPagesMax: Int? = nil,
                               borderWidthPx: Float? = nil,
                               borderColor: SIMD4<Float>? = nil,
                               beamColor: SIMD4<Float>? = nil,
                               collisionPaddingPx: Float? = nil,
                               groupingThreshold: Int? = nil,
                               maxOffsetPx: Float? = nil,
                               collisionIterations: Int? = nil,
                               springK: Float? = nil,
                               smoothing: Float? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.avatarSettings(size: size,
                                                     sizeScale: sizeScale,
                                                     compressedScale: compressedScale,
                                                     atlasSizePx: atlasSizePx,
                                                     atlasPagesMax: atlasPagesMax,
                                                     borderWidthPx: borderWidthPx,
                                                     borderColor: borderColor,
                                                     beamColor: beamColor,
                                                     collisionPaddingPx: collisionPaddingPx,
                                                     groupingThreshold: groupingThreshold,
                                                     maxOffsetPx: maxOffsetPx,
                                                     collisionIterations: collisionIterations,
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
