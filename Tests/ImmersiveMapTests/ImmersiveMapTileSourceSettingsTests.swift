// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

@MainActor
final class ImmersiveMapTileSourceSettingsTests: XCTestCase {
    @MainActor
    func testImmersiveMapViewModifiersAttachControllersAndInitialCameraPosition() {
        let avatars = ImmersiveMapAvatarsController()
        let camera = ImmersiveMapCameraController()
        let selection = ImmersiveMapSelectionController()
        let cameraPosition = ImmersiveMapCameraPosition(latitudeDegrees: 55.7558,
                                                        longitudeDegrees: 37.6173,
                                                        zoom: 12,
                                                        bearing: .pi / 10,
                                                        pitch: .pi / 5)

        let view = ImmersiveMapView()
            .avatars(avatars)
            .camera(camera, position: cameraPosition)
            .selection(selection)

        let reflectedAvatars: ImmersiveMapAvatarsController? = reflectedObject("avatarsController", in: view)
        let reflectedCamera: ImmersiveMapCameraController? = reflectedObject("cameraController", in: view)
        let reflectedSelection: ImmersiveMapSelectionController? = reflectedObject("selectionController", in: view)

        XCTAssertTrue(reflectedAvatars === avatars)
        XCTAssertTrue(reflectedCamera === camera)
        XCTAssertTrue(reflectedSelection === selection)
        XCTAssertEqual(reflectedValue("cameraPosition", in: view), cameraPosition)
    }

    func testImmersiveMapViewCameraControllerAndUIControlsAreSeparateModifiers() {
        let camera = ImmersiveMapCameraController()
        let cameraPosition = ImmersiveMapCameraPosition(latitudeDegrees: 55.7558,
                                                        longitudeDegrees: 37.6173,
                                                        zoom: 12,
                                                        bearing: .pi / 10,
                                                        pitch: .pi / 5)

        let controlledView = ImmersiveMapView()
            .cameraController(camera, position: cameraPosition)
        let controlsView = controlledView
            .enableCameraUIControls()

        let reflectedCamera: ImmersiveMapCameraController? = reflectedObject("cameraController", in: controlledView)
        XCTAssertTrue(reflectedCamera === camera)
        XCTAssertEqual(reflectedValue("cameraPosition", in: controlledView), cameraPosition)
        XCTAssertFalse(String(describing: type(of: controlsView)).isEmpty)
    }

    func testCameraUIControlsPreserveImmersiveMapViewBuilderModifiers() throws {
        let camera = ImmersiveMapCameraController()

        let view = ImmersiveMapView()
            .cameraController(camera)
            .enableCameraUIControls()
            .debugPanel()

        let settings: ImmersiveMapSettings? = reflectedValue("settings", in: view)
        let unwrappedSettings = try XCTUnwrap(settings)
        XCTAssertTrue(unwrappedSettings.debug.enableDebugPanel)
    }

    func testDebugPanelEnablesDebugOverlaySettings() {
        let settings = ImmersiveMapSettings.default.debugPanel()

        XCTAssertTrue(settings.debug.enableDebugPanel)
    }

    func testTileProviderAndMapStyleSettingsModifiersStoreBuiltInConfiguration() {
        let style = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault.labels { labels in
            labels.town.haloEm = 0.125
        }

        let tileProvider = ImmersiveMapTilesProvider(apiKey: "tiles-key")
        let mapStyle = ImmersiveMapTilesMapStyle(configuration: style)
        let settings = ImmersiveMapSettings.default
            .tileProvider(tileProvider)
            .mapStyle(mapStyle)

        XCTAssertEqual(settings.tileProvider, AnyImmersiveMapTileProvider(tileProvider))
        XCTAssertEqual(settings.mapStyle, AnyImmersiveMapMapStyle(mapStyle))
        XCTAssertNotEqual(settings, ImmersiveMapSettings.default)
    }

    func testTileProviderAndMapStyleViewModifiersStoreBuiltInConfiguration() throws {
        let style = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault.labels { labels in
            labels.poi.haloEm = 0.35
        }
        let tileProvider = ImmersiveMapTilesProvider(apiKey: "tiles-key")
        let mapStyle = ImmersiveMapTilesMapStyle(configuration: style)

        let view = ImmersiveMapView()
            .tileProvider(tileProvider)
            .mapStyle(mapStyle)

        let settings: ImmersiveMapSettings? = reflectedValue("settings", in: view)
        let unwrappedSettings = try XCTUnwrap(settings)
        XCTAssertEqual(unwrappedSettings.tileProvider, AnyImmersiveMapTileProvider(tileProvider))
        XCTAssertEqual(unwrappedSettings.mapStyle, AnyImmersiveMapMapStyle(mapStyle))
    }

    func testTileURLTemplateModifierConfiguresTheBuiltInProviderWithTheTemplateSource() throws {
        let view = ImmersiveMapView()
            .tileURLTemplate("https://tiles.com/{x}/{y}/{z}?apiKey=xxx",
                             headers: ["X-Client": "demo"])

        let settings: ImmersiveMapSettings? = reflectedValue("settings", in: view)
        let unwrappedSettings = try XCTUnwrap(settings)
        let provider = unwrappedSettings.tileProvider
        XCTAssertEqual(provider.id, "immersivemaptiles")
        XCTAssertEqual(provider.tileSource.urlTemplate, "https://tiles.com/{x}/{y}/{z}?apiKey=xxx")
        XCTAssertEqual(provider.tileSource.headers, ["X-Client": "demo"])
        XCTAssertEqual(unwrappedSettings.tiles.network.tileURLTemplate,
                       "https://tiles.com/{x}/{y}/{z}?apiKey=xxx")
        XCTAssertEqual(unwrappedSettings.tiles.network.tileRequestHeaders, ["X-Client": "demo"])
    }

    func testEarthSceneModifierControlsFullSunAndTerminatorPackage() {
        let settings = ImmersiveMapSettings.default.earthScene(isEnabled: false)

        XCTAssertFalse(settings.scene.earth.isEnabled)
        XCTAssertTrue(settings.scene.earth.sun.isEnabled)
    }

    func testCacheSettingsLegacyInitializerFunctionReferenceUsesDefaultPreparedDiskCacheSize() {
        let initialize: (Bool, Bool, Bool, Bool, TimeInterval, Int) -> ImmersiveMapSettings.TileSettings.CacheSettings =
            ImmersiveMapSettings.TileSettings.CacheSettings.init

        let cache = initialize(true, false, false, false, 34, 56)

        XCTAssertTrue(cache.clearDiskCachesOnLaunch)
        XCTAssertFalse(cache.urlCacheEnabled)
        XCTAssertFalse(cache.preparedTileCacheEnabled)
        XCTAssertFalse(cache.preparedDiskCompressionEnabled)
        XCTAssertEqual(cache.preparedDiskTimeToLive, 34)
        XCTAssertEqual(cache.preparedDiskCacheSizeInBytes,
                       ImmersiveMapSettings.TileSettings.CacheSettings.defaultPreparedDiskCacheSizeInBytes)
        XCTAssertEqual(cache.memoryCacheSizeInBytes, 56)
    }

    func testTileCacheSettingsLegacyModifierFunctionReferencePreservesPreparedDiskCacheSize() {
        var baseSettings = ImmersiveMapSettings.default
        baseSettings.tiles.cache.preparedDiskCacheSizeInBytes = 45
        let modify: (Bool?, Bool?, Bool?, Bool?, TimeInterval?, Int?) -> ImmersiveMapSettings =
            baseSettings.tileSettings

        let settings = modify(true, false, false, false, 78, 90)

        XCTAssertTrue(settings.tiles.cache.clearDiskCachesOnLaunch)
        XCTAssertFalse(settings.tiles.cache.urlCacheEnabled)
        XCTAssertFalse(settings.tiles.cache.preparedTileCacheEnabled)
        XCTAssertFalse(settings.tiles.cache.preparedDiskCompressionEnabled)
        XCTAssertEqual(settings.tiles.cache.preparedDiskTimeToLive, 78)
        XCTAssertEqual(settings.tiles.cache.preparedDiskCacheSizeInBytes, 45)
        XCTAssertEqual(settings.tiles.cache.memoryCacheSizeInBytes, 90)
    }

    func testTileCacheSettingsModifierUpdatesOnlyProvidedCacheValues() {
        var baseTiles = ImmersiveMapSettings.default.tiles
        baseTiles.network.maxConcurrentFetches = 11
        baseTiles.network.pendingRequestQueueCapacity = 27
        baseTiles.parsing.addTestBorders = true
        baseTiles.cache.clearDiskCachesOnLaunch = false
        baseTiles.cache.preparedDiskTimeToLive = 34
        baseTiles.cache.preparedDiskCacheSizeInBytes = 45
        baseTiles.cache.memoryCacheSizeInBytes = 56

        let settings = ImmersiveMapSettings.default
            .tileSettings(baseTiles)
            .tileSettings(clearDiskCachesOnLaunch: true,
                          preparedDiskTimeToLive: 78,
                          preparedDiskCacheSizeInBytes: 89)

        XCTAssertEqual(settings.tiles.network, baseTiles.network)
        XCTAssertEqual(settings.tiles.parsing, baseTiles.parsing)
        XCTAssertEqual(settings.tiles.coverage, baseTiles.coverage)
        XCTAssertTrue(settings.tiles.cache.clearDiskCachesOnLaunch)
        XCTAssertEqual(settings.tiles.cache.preparedDiskTimeToLive, 78)
        XCTAssertEqual(settings.tiles.cache.preparedDiskCacheSizeInBytes, 89)
        XCTAssertEqual(settings.tiles.cache.memoryCacheSizeInBytes, 56)
        XCTAssertEqual(ImmersiveMapSettings.default.tiles.cache.preparedDiskCacheSizeInBytes,
                       ImmersiveMapSettings.TileSettings.CacheSettings.defaultPreparedDiskCacheSizeInBytes)
    }

    func testAvatarSettingsModifierUpdatesOnlyProvidedAvatarValues() {
        let settings = ImmersiveMapSettings.default
            .avatarSettings(size: .px128,
                            sizeScale: 2.0,
                            borderWidthPx: 4.0)

        XCTAssertEqual(settings.avatars.size, .px128)
        XCTAssertEqual(settings.avatars.sizeScale, 2.0)
        XCTAssertEqual(settings.avatars.borderWidthPx, 4.0)
        XCTAssertEqual(settings.avatars.compressedScale, ImmersiveMapSettings.default.avatars.compressedScale)
        XCTAssertEqual(settings.avatars.groupingThreshold, ImmersiveMapSettings.default.avatars.groupingThreshold)
        XCTAssertEqual(settings.avatars.collisionPaddingPx, ImmersiveMapSettings.default.avatars.collisionPaddingPx)
    }

    func testAvatarSettingsSizeSupportsLargeTextureGrid() {
        XCTAssertEqual(ImmersiveMapSettings.AvatarSettings.Size.px64.rawValue, 64)
        XCTAssertEqual(ImmersiveMapSettings.AvatarSettings.Size.px128.rawValue, 128)
        XCTAssertEqual(ImmersiveMapSettings.AvatarSettings.Size.px256.rawValue, 256)
        XCTAssertEqual(ImmersiveMapSettings.AvatarSettings.Size.px512.rawValue, 512)
        XCTAssertEqual(ImmersiveMapSettings.AvatarSettings.Size.px1024.rawValue, 1024)
        XCTAssertEqual(ImmersiveMapSettings.AvatarSettings.Size.px2048.rawValue, 2048)
    }

    func testImmersiveMapViewLegacyTileCacheSettingsModifierFunctionReferencePreservesPreparedDiskCacheSize() {
        var baseSettings = ImmersiveMapSettings.default
        baseSettings.tiles.cache.preparedDiskCacheSizeInBytes = 45
        let modify: (Bool?, Bool?, Bool?, Bool?, TimeInterval?, Int?) -> ImmersiveMapView =
            ImmersiveMapView(settings: baseSettings).tileSettings

        let view = modify(true, false, false, false, 78, 90)
        let settings: ImmersiveMapSettings? = reflectedValue("settings", in: view)

        XCTAssertTrue(settings?.tiles.cache.clearDiskCachesOnLaunch == true)
        XCTAssertFalse(settings?.tiles.cache.urlCacheEnabled == true)
        XCTAssertFalse(settings?.tiles.cache.preparedTileCacheEnabled == true)
        XCTAssertFalse(settings?.tiles.cache.preparedDiskCompressionEnabled == true)
        XCTAssertEqual(settings?.tiles.cache.preparedDiskTimeToLive, 78)
        XCTAssertEqual(settings?.tiles.cache.preparedDiskCacheSizeInBytes, 45)
        XCTAssertEqual(settings?.tiles.cache.memoryCacheSizeInBytes, 90)
    }

    func testImmersiveMapViewTileCacheSettingsModifierUpdatesOnlyProvidedCacheValues() {
        let view = ImmersiveMapView()
            .tileSettings(clearDiskCachesOnLaunch: true,
                          preparedDiskCacheSizeInBytes: 64,
                          memoryCacheSizeInBytes: 128)

        let settings: ImmersiveMapSettings? = reflectedValue("settings", in: view)

        XCTAssertTrue(settings?.tiles.cache.clearDiskCachesOnLaunch == true)
        XCTAssertEqual(settings?.tiles.cache.preparedDiskCacheSizeInBytes, 64)
        XCTAssertEqual(settings?.tiles.cache.memoryCacheSizeInBytes, 128)
        XCTAssertEqual(settings?.tiles.cache.preparedDiskTimeToLive,
                       ImmersiveMapSettings.default.tiles.cache.preparedDiskTimeToLive)
    }

    func testImmersiveMapViewAvatarSettingsModifierUpdatesOnlyProvidedAvatarValues() throws {
        let view = ImmersiveMapView()
            .avatarSettings(size: .px128,
                            sizeScale: 2.0,
                            borderWidthPx: 4.0)

        let settings: ImmersiveMapSettings? = reflectedValue("settings", in: view)
        let avatars = try XCTUnwrap(settings?.avatars)

        XCTAssertEqual(avatars.size, .px128)
        XCTAssertEqual(avatars.sizeScale, 2.0)
        XCTAssertEqual(avatars.borderWidthPx, 4.0)
        XCTAssertEqual(avatars.compressedScale, ImmersiveMapSettings.default.avatars.compressedScale)
        XCTAssertEqual(avatars.groupingThreshold, ImmersiveMapSettings.default.avatars.groupingThreshold)
        XCTAssertEqual(avatars.collisionPaddingPx, ImmersiveMapSettings.default.avatars.collisionPaddingPx)
    }

    func testImmersiveMapViewEarthSceneModifierControlsFullSunAndTerminatorPackage() {
        let view = ImmersiveMapView().earthScene(isEnabled: false)

        let settings: ImmersiveMapSettings? = reflectedValue("settings", in: view)

        XCTAssertFalse(settings?.scene.earth.isEnabled == true)
        XCTAssertTrue(settings?.scene.earth.sun.isEnabled == true)
    }

    func testFluentSettingsModifiersReplaceEverySettingsDomain() {
        let renderLoop = ImmersiveMapSettings.RenderLoopSettings(forceContinuousRendering: true,
                                                                 interactionFramesPerSecond: 30,
                                                                 labelFadeFramesPerSecond: 15)
        let camera = ImmersiveMapSettings.CameraSettings(maximumPitch: 1,
                                                         maximumZoom: 17,
                                                         focusedMarkerZoom: 14,
                                                         globeMinimumAbsoluteBearing: 0.5,
                                                         globeBearingUnlockZoom: 4,
                                                         gesturePanTranslationScale: 1,
                                                         worldPanSensitivity: 2,
                                                         worldPanSpeed: 3,
                                                         pinchZoomFactor: 4,
                                                         pinchZoomVelocityFactor: 5,
                                                         pinchZoomVelocityLimit: 6,
                                                         dragZoomFactor: 7,
                                                         dragZoomVelocityFactor: 8,
                                                         dragZoomVelocityLimit: 9,
                                                         rotationGestureSensitivity: 10)
        let presentation = ImmersiveMapSettings.PresentationSettings(automaticTransitionStartZoom: 1,
                                                                     automaticTransitionSpan: 2,
                                                                     globeRadiusScale: 3)
        let tiles = ImmersiveMapSettings.default.tiles
        let labels = ImmersiveMapSettings.default.labels
        let scene = ImmersiveMapSettings.default.scene
        let style = ImmersiveMapSettings.default.style
        let avatars = ImmersiveMapSettings.default.avatars
        let attribution = ImmersiveMapSettings.AttributionSettings(
            isVisible: false,
            size: .large,
            position: .topLeading,
            textColor: SIMD4<Float>(1, 0, 0, 1),
            isProvidedExternally: true,
            attributionOverride: ImmersiveMapAttribution(title: "Tiles", copyright: "Copyright")
        )
        let postProcessing = ImmersiveMapSettings.PostProcessingSettings(fxaaEnabled: true)
        let debug = ImmersiveMapSettings.DebugSettings(enableDebugPanel: true,
                                                       coordinateScale: 1,
                                                       diagnosticsScale: 2,
                                                       leftPadding: 3,
                                                       topPadding: 4,
                                                       sectionSpacing: 5,
                                                       textColor: SIMD3<Float>(6, 7, 8))

        let settings = ImmersiveMapSettings.default
            .renderLoopSettings(renderLoop)
            .cameraSettings(camera)
            .presentationSettings(presentation)
            .tileSettings(tiles)
            .labelSettings(labels)
            .sceneSettings(scene)
            .styleSettings(style)
            .avatarSettings(avatars)
            .attributionSettings(attribution)
            .postProcessingSettings(postProcessing)
            .debugSettings(debug)

        XCTAssertEqual(settings.renderLoop, renderLoop)
        XCTAssertEqual(settings.camera, camera)
        XCTAssertEqual(settings.presentation, presentation)
        XCTAssertEqual(settings.tiles, tiles)
        XCTAssertEqual(settings.labels, labels)
        XCTAssertEqual(settings.scene, scene)
        XCTAssertEqual(settings.style, style)
        XCTAssertEqual(settings.avatars, avatars)
        XCTAssertEqual(settings.attribution, attribution)
        XCTAssertEqual(settings.postProcessing, postProcessing)
        XCTAssertEqual(settings.debug, debug)
    }

    func testVectorTileProviderConfiguresGenericURLAndBearerToken() {
        let url = URL(string: "https://tiles.example.com/vector")!
        let provider = VectorTileProvider(
            id: "custom",
            tileSource: .url(url).token("public-token"),
            maximumTileZoomLevel: 12
        )

        let settings = ImmersiveMapSettings.default.tileProvider(provider)

        XCTAssertEqual(settings.tiles.network.tileBaseURL, url)
        XCTAssertEqual(settings.tiles.network.authorizationToken, "public-token")
        XCTAssertEqual(settings.tiles.network.authorizationMode, .bearerHeader)
        XCTAssertEqual(settings.tileProvider, AnyImmersiveMapTileProvider(provider))
        XCTAssertEqual(settings.tiles.coverage.maximumZoomLevel, 12)
    }

    func testVectorTileProviderUpdatesNetworkURLTokenAndAuthorizationMode() {
        let url = URL(string: "https://tiles.example.com/vector")!
        let provider = VectorTileProvider(
            id: "custom-query",
            tileSource: ImmersiveMapTileSource(tileBaseURL: url,
                                               accessToken: "public-token",
                                               authorization: .accessTokenQuery(parameterName: "access_token"))
        )

        let settings = ImmersiveMapSettings.default.tileProvider(provider)

        XCTAssertEqual(settings.tiles.network.tileBaseURL, url)
        XCTAssertEqual(settings.tiles.network.authorizationToken, "public-token")
        XCTAssertEqual(settings.tiles.network.authorizationMode, .accessTokenQuery(parameterName: "access_token"))
    }

    private func reflectedValue<T>(_ label: String, in value: Any) -> T? {
        Mirror(reflecting: value).children.first { $0.label == label }?.value as? T
    }

    private func reflectedObject<T: AnyObject>(_ label: String, in value: Any) -> T? {
        reflectedValue(label, in: value)
    }
}
