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
    private var sceneModelsController: ImmersiveMapSceneModelsController?
    private var cameraController: ImmersiveMapCameraController?
    private var cameraUIControls: CameraUIControls?
    private var selectionController: ImmersiveMapSelectionController?
    private var avatarTapAction: ((ImmersiveMapAvatarTapEvent) -> Void)?
    private var markerContent: MarkerViewContent?
    private var tourVideoRecorder: ImmersiveMapTourVideoRecorder?
    private var apiKey: String?

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

    /// The body tree is identity-stable under any combination of modifiers:
    /// toggling `enableCameraUIControls` must not change the tree type,
    /// otherwise SwiftUI destroys and recreates the entire platform map view
    /// (renderer, caches, controller bindings).
    public var body: some View {
        ImmersiveMapUIViewRepresentable(settings: resolvedSettings,
                                        avatarsController: avatarsController,
                                        sceneModelsController: sceneModelsController,
                                        cameraPosition: cameraPosition,
                                        cameraController: cameraController,
                                        selectionController: selectionController,
                                        avatarTapAction: avatarTapAction,
                                        markerContent: markerContent,
                                        tourVideoRecorder: tourVideoRecorder)
            .immersiveMapCameraControlsOverlay(
                isEnabled: (cameraUIControls?.isEnabled ?? false) && cameraController != nil,
                camera: cameraController,
                initialCameraPosition: cameraPosition ?? Self.defaultCameraControlsPosition,
                maximumPitch: cameraUIControls?.maximumPitch ?? ImmersiveMapSettings.default.camera.maximumPitch
            )
    }

    /// The key is applied here rather than in the modifier so that `apiKey` and
    /// `tileProvider` can be written in either order: attaching a provider
    /// replaces the whole authorization block, which would otherwise silently
    /// drop a key set before it.
    var resolvedSettings: ImmersiveMapSettings {
        guard let apiKey, apiKey.isEmpty == false else { return settings }
        return settings.apiKey(apiKey)
    }
}

#if canImport(UIKit)
private struct ImmersiveMapUIViewRepresentable: UIViewRepresentable {
    let settings: ImmersiveMapSettings
    let avatarsController: ImmersiveMapAvatarsController?
    let sceneModelsController: ImmersiveMapSceneModelsController?
    let cameraPosition: ImmersiveMapCameraPosition?
    let cameraController: ImmersiveMapCameraController?
    let selectionController: ImmersiveMapSelectionController?
    let avatarTapAction: ((ImmersiveMapAvatarTapEvent) -> Void)?
    let markerContent: MarkerViewContent?
    let tourVideoRecorder: ImmersiveMapTourVideoRecorder?

    public func makeUIView(context: Context) -> ImmersiveMapUIView {
        let uiView = ImmersiveMapUIView(frame: .zero,
                                        settings: settings,
                                        avatarsController: avatarsController,
                                        sceneModelsController: sceneModelsController,
                                        cameraPosition: cameraPosition,
                                        cameraController: cameraController,
                                        selectionController: selectionController,
                                        avatarTapAction: avatarTapAction,
                                        markerContent: markerContent)
        return uiView
    }

    public func updateUIView(_ uiView: ImmersiveMapUIView, context: Context) {
        uiView.update(settings: settings,
                      avatarsController: avatarsController,
                      sceneModelsController: sceneModelsController,
                      cameraController: cameraController,
                      selectionController: selectionController,
                      avatarTapAction: avatarTapAction,
                      markerContent: markerContent,
                      cameraPosition: cameraPosition,
                      tourVideoRecorder: tourVideoRecorder)
    }

    public static func dismantleUIView(_ uiView: ImmersiveMapUIView, coordinator: ()) {
        uiView.dismantle()
    }
}
#elseif canImport(AppKit)
private struct ImmersiveMapUIViewRepresentable: NSViewRepresentable {
    let settings: ImmersiveMapSettings
    let avatarsController: ImmersiveMapAvatarsController?
    let sceneModelsController: ImmersiveMapSceneModelsController?
    let cameraPosition: ImmersiveMapCameraPosition?
    let cameraController: ImmersiveMapCameraController?
    let selectionController: ImmersiveMapSelectionController?
    let avatarTapAction: ((ImmersiveMapAvatarTapEvent) -> Void)?
    let markerContent: MarkerViewContent?
    let tourVideoRecorder: ImmersiveMapTourVideoRecorder?

    public func makeNSView(context: Context) -> ImmersiveMapNSView {
        let nsView = ImmersiveMapNSView(frame: .zero,
                                        settings: settings,
                                        avatarsController: avatarsController,
                                        sceneModelsController: sceneModelsController,
                                        cameraPosition: cameraPosition,
                                        cameraController: cameraController,
                                        selectionController: selectionController,
                                        avatarTapAction: avatarTapAction,
                                        markerContent: markerContent)
        return nsView
    }

    public func updateNSView(_ nsView: ImmersiveMapNSView, context: Context) {
        nsView.update(settings: settings,
                      avatarsController: avatarsController,
                      sceneModelsController: sceneModelsController,
                      cameraController: cameraController,
                      selectionController: selectionController,
                      avatarTapAction: avatarTapAction,
                      markerContent: markerContent,
                      cameraPosition: cameraPosition,
                      tourVideoRecorder: tourVideoRecorder)
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

    /// Attaches 3D scene models anchored at geo coordinates. Models render
    /// inside the map world pass (with depth: hidden behind the globe horizon
    /// and, in solid building mode, behind buildings) in flat, globe, and the
    /// morph between them. See ``ImmersiveMapSceneModelsController``.
    func sceneModels(_ controller: ImmersiveMapSceneModelsController?) -> ImmersiveMapView {
        var view = self
        view.sceneModelsController = controller
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

    /// Attaches a tour video recorder to this map. The recorder exports camera
    /// tours offline using the map's current configuration (tile provider,
    /// style, labels, avatars); see ``ImmersiveMapTourVideoRecorder``.
    func tourVideoRecorder(_ recorder: ImmersiveMapTourVideoRecorder?) -> ImmersiveMapView {
        var view = self
        view.tourVideoRecorder = recorder
        return view
    }

    /// Calls `action` on every tap on an avatar marker.
    /// Works without ``ImmersiveMapSelectionController``: the event arrives even
    /// when selection is not used, and again on a tap on an already selected marker.
    func onAvatarTap(_ action: @escaping (ImmersiveMapAvatarTapEvent) -> Void) -> ImmersiveMapView {
        var view = self
        view.avatarTapAction = action
        return view
    }

    /// Declarative SwiftUI markers bound to geo coordinates.
    /// The content is repositioned on every rendered frame (flat, globe and
    /// the morph between them); beyond the globe's horizon the marker fades
    /// out by alpha. Touches inside a marker are handled by the content itself
    /// (Button, onTapGesture); touches outside the markers go to the map.
    /// A repeated call replaces the previous set entirely. Z-order equals the
    /// collection order: the last element is on top.
    func markers<Items: RandomAccessCollection, Content: View>(
        _ items: Items,
        coordinate: (Items.Element) -> GeoCoordinate,
        anchor: UnitPoint = .center,
        @ViewBuilder content: (Items.Element) -> Content
    ) -> ImmersiveMapView where Items.Element: Identifiable {
        var view = self
        view.markerContent = MarkerViewContent(
            anchor: anchor,
            items: items.map { item in
                MarkerViewItem(id: AnyHashable(item.id),
                               coordinate: coordinate(item),
                               content: AnyView(content(item)))
            }
        )
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

    /// Authorises tile requests with an API key.
    ///
    /// Get one at https://immersivemap.dev/account. Without a key the map still
    /// renders — the hosted service keeps a shared, rate-limited public pool —
    /// so a key buys your own budget rather than access.
    ///
    ///     ImmersiveMapView()
    ///         .apiKey("im_…")
    ///
    /// The key is sent as an `Authorization: Bearer` header, not a query
    /// parameter, so tiles stay on one shared CDN cache entry instead of one
    /// copy per key. It applies to whichever provider is configured, and may be
    /// written before or after `tileProvider`.
    public func apiKey(_ apiKey: String?) -> ImmersiveMapView {
        var view = self
        view.apiKey = apiKey
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
                             preparedDiskCompressionEnabled: Bool? = nil,
                             preparedDiskTimeToLive: TimeInterval? = nil,
                             memoryCacheSizeInBytes: Int? = nil) -> ImmersiveMapView {
        tileSettings(clearDiskCachesOnLaunch: clearDiskCachesOnLaunch,
                     urlCacheEnabled: urlCacheEnabled,
                     preparedTileCacheEnabled: preparedTileCacheEnabled,
                     preparedDiskCompressionEnabled: preparedDiskCompressionEnabled,
                     preparedDiskTimeToLive: preparedDiskTimeToLive,
                     preparedDiskCacheSizeInBytes: nil,
                     memoryCacheSizeInBytes: memoryCacheSizeInBytes)
    }

    public func tileSettings(clearDiskCachesOnLaunch: Bool? = nil,
                             urlCacheEnabled: Bool? = nil,
                             preparedTileCacheEnabled: Bool? = nil,
                             preparedDiskCompressionEnabled: Bool? = nil,
                             preparedDiskTimeToLive: TimeInterval? = nil,
                             preparedDiskCacheSizeInBytes: Int?,
                             memoryCacheSizeInBytes: Int? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.tileSettings(
            clearDiskCachesOnLaunch: clearDiskCachesOnLaunch,
            urlCacheEnabled: urlCacheEnabled,
            preparedTileCacheEnabled: preparedTileCacheEnabled,
            preparedDiskCompressionEnabled: preparedDiskCompressionEnabled,
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

    /// World-space direction pointing towards the static sun
    /// (+X east, +Y north, +Z up). Defines where buildings and scene models
    /// cast their shadows.
    public func sceneLight(direction: SIMD3<Float>) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.sceneLight(direction: direction)
        return view
    }

    /// Directional shadows cast by buildings and scene models in the flat
    /// presentation.
    public func shadowSettings(_ shadows: ImmersiveMapSettings.ShadowSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.shadowSettings(shadows)
        return view
    }

    public func shadows(isEnabled: Bool = true) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.shadows(isEnabled: isEnabled)
        return view
    }

    public func styleSettings(_ style: ImmersiveMapSettings.StyleSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.styleSettings(style)
        return view
    }

    /// Display mode for extruded 3D buildings in the flat presentation:
    /// `.translucent` - semi-transparent (default), `.solid` - opaque,
    /// `.solidAtHighZoom` - smooth transition from semi-transparent to opaque
    /// over a zoom range (default 17...18).
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
