// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

public struct ImmersiveMapSettings: Equatable, Sendable {
    public struct LabelLanguage: Hashable, Codable, Sendable {
        public let code: String

        public init(_ code: String) {
            let normalized = code
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
            self.code = normalized.isEmpty ? Self.english.code : normalized
        }

        public var providerFieldSuffix: String {
            code.split(separator: "-").first.map(String.init) ?? Self.english.code
        }

        public var preparedTileCacheNamespaceKey: String {
            String(code.unicodeScalars.map { scalar in
                switch scalar.value {
                case 45, 48...57, 97...122:
                    return Character(scalar)
                default:
                    return "_"
                }
            })
        }

        public static let english = LabelLanguage("en")
        public static let russian = LabelLanguage("ru")
        public static let french = LabelLanguage("fr")
        public static let german = LabelLanguage("de")
        public static let spanish = LabelLanguage("es")
        public static let italian = LabelLanguage("it")
        public static let portuguese = LabelLanguage("pt")
        public static let turkish = LabelLanguage("tr")
    }

    public enum LabelFallbackPolicy: String, Codable, Sendable {
        case international
        case localFirst
    }

    public struct RenderLoopSettings: Equatable, Sendable {
        public var forceContinuousRendering: Bool
        public var interactionFramesPerSecond: Int
        public var labelFadeFramesPerSecond: Int

        public init(forceContinuousRendering: Bool,
                    interactionFramesPerSecond: Int,
                    labelFadeFramesPerSecond: Int) {
            self.forceContinuousRendering = forceContinuousRendering
            self.interactionFramesPerSecond = interactionFramesPerSecond
            self.labelFadeFramesPerSecond = labelFadeFramesPerSecond
        }
    }

    public struct CameraSettings: Equatable, Sendable {
        public var maximumPitch: Float
        public var maximumZoom: Double
        public var focusedMarkerZoom: Double
        public var globeMinimumAbsoluteBearing: Float
        public var globeBearingUnlockZoom: Double
        public var globePitchUnlockZoom: Double
        public var highZoomPitchExtension: Float
        public var highZoomPitchExtensionStartZoom: Double
        public var highZoomPitchExtensionEndZoom: Double
        public var extraHighZoomPitchExtension: Float
        public var extraHighZoomPitchExtensionStartZoom: Double
        public var extraHighZoomPitchExtensionEndZoom: Double
        public var gesturePanTranslationScale: Double
        public var worldPanSensitivity: Double
        public var worldPanSpeed: Double
        public var pinchZoomFactor: Double
        public var pinchZoomVelocityFactor: Double
        public var pinchZoomVelocityLimit: Double
        /// Доля притяжения зума к точке жеста (курсор, центр pinch, двойной tap):
        /// 1 — точка мира под курсором остаётся на месте, 0 — зум в центр экрана.
        public var zoomAnchorFactor: Double
        public var dragZoomFactor: Double
        public var dragZoomVelocityFactor: Double
        public var dragZoomVelocityLimit: Double
        public var rotationGestureSensitivity: Float
        public var globePanInertiaEnabled: Bool
        public var globePanInertiaHalfLife: Double
        public var globePanInertiaActivationVelocity: Double
        public var globePanInertiaStopVelocity: Double
        public var globePanInertiaMaxInitialVelocity: Double
        public var pitchFollowEnabled: Bool
        public var pitchFollowHalfLife: Double
        public var bearingFollowEnabled: Bool
        public var bearingFollowHalfLife: Double

        public init(maximumPitch: Float,
                    maximumZoom: Double,
                    focusedMarkerZoom: Double,
                    globeMinimumAbsoluteBearing: Float,
                    globeBearingUnlockZoom: Double,
                    globePitchUnlockZoom: Double = 3.0,
                    highZoomPitchExtension: Float = 0,
                    highZoomPitchExtensionStartZoom: Double = 15.0,
                    highZoomPitchExtensionEndZoom: Double = 16.0,
                    extraHighZoomPitchExtension: Float = 0,
                    extraHighZoomPitchExtensionStartZoom: Double = 18.4,
                    extraHighZoomPitchExtensionEndZoom: Double = 20.0,
                    gesturePanTranslationScale: Double,
                    worldPanSensitivity: Double,
                    worldPanSpeed: Double,
                    pinchZoomFactor: Double,
                    pinchZoomVelocityFactor: Double,
                    pinchZoomVelocityLimit: Double,
                    zoomAnchorFactor: Double = 1.0,
                    dragZoomFactor: Double,
                    dragZoomVelocityFactor: Double,
                    dragZoomVelocityLimit: Double,
                    rotationGestureSensitivity: Float,
                    globePanInertiaEnabled: Bool = true,
                    globePanInertiaHalfLife: Double = 0.28,
                    globePanInertiaActivationVelocity: Double = 450.0,
                    globePanInertiaStopVelocity: Double = 60.0,
                    globePanInertiaMaxInitialVelocity: Double = 7000.0,
                    pitchFollowEnabled: Bool = true,
                    pitchFollowHalfLife: Double = 0.06,
                    bearingFollowEnabled: Bool = true,
                    bearingFollowHalfLife: Double = 0.06) {
            self.maximumPitch = maximumPitch
            self.maximumZoom = maximumZoom
            self.focusedMarkerZoom = focusedMarkerZoom
            self.globeMinimumAbsoluteBearing = globeMinimumAbsoluteBearing
            self.globeBearingUnlockZoom = globeBearingUnlockZoom
            self.globePitchUnlockZoom = globePitchUnlockZoom
            self.highZoomPitchExtension = highZoomPitchExtension
            self.highZoomPitchExtensionStartZoom = highZoomPitchExtensionStartZoom
            self.highZoomPitchExtensionEndZoom = highZoomPitchExtensionEndZoom
            self.extraHighZoomPitchExtension = extraHighZoomPitchExtension
            self.extraHighZoomPitchExtensionStartZoom = extraHighZoomPitchExtensionStartZoom
            self.extraHighZoomPitchExtensionEndZoom = extraHighZoomPitchExtensionEndZoom
            self.gesturePanTranslationScale = gesturePanTranslationScale
            self.worldPanSensitivity = worldPanSensitivity
            self.worldPanSpeed = worldPanSpeed
            self.pinchZoomFactor = pinchZoomFactor
            self.pinchZoomVelocityFactor = pinchZoomVelocityFactor
            self.pinchZoomVelocityLimit = pinchZoomVelocityLimit
            self.zoomAnchorFactor = zoomAnchorFactor
            self.dragZoomFactor = dragZoomFactor
            self.dragZoomVelocityFactor = dragZoomVelocityFactor
            self.dragZoomVelocityLimit = dragZoomVelocityLimit
            self.rotationGestureSensitivity = rotationGestureSensitivity
            self.globePanInertiaEnabled = globePanInertiaEnabled
            self.globePanInertiaHalfLife = globePanInertiaHalfLife
            self.globePanInertiaActivationVelocity = globePanInertiaActivationVelocity
            self.globePanInertiaStopVelocity = globePanInertiaStopVelocity
            self.globePanInertiaMaxInitialVelocity = globePanInertiaMaxInitialVelocity
            self.pitchFollowEnabled = pitchFollowEnabled
            self.pitchFollowHalfLife = pitchFollowHalfLife
            self.bearingFollowEnabled = bearingFollowEnabled
            self.bearingFollowHalfLife = bearingFollowHalfLife
        }

        func pitchExtension(at zoom: Double) -> Float {
            interpolatedPitchExtension(at: zoom,
                                       extensionAngle: highZoomPitchExtension,
                                       startZoom: highZoomPitchExtensionStartZoom,
                                       endZoom: highZoomPitchExtensionEndZoom)
            + interpolatedPitchExtension(at: zoom,
                                         extensionAngle: extraHighZoomPitchExtension,
                                         startZoom: extraHighZoomPitchExtensionStartZoom,
                                         endZoom: extraHighZoomPitchExtensionEndZoom)
        }

        func maximumReachablePitch(at zoom: Double) -> Float {
            max(maximumPitch, 0) + pitchExtension(at: zoom)
        }

        private func interpolatedPitchExtension(at zoom: Double,
                                                extensionAngle: Float,
                                                startZoom: Double,
                                                endZoom: Double) -> Float {
            let clampedExtensionAngle = max(extensionAngle, 0)
            guard clampedExtensionAngle > 0 else {
                return 0
            }

            let clampedEndZoom = max(endZoom, startZoom)
            guard clampedEndZoom - startZoom > Double.leastNonzeroMagnitude else {
                return zoom >= startZoom ? clampedExtensionAngle : 0
            }

            let progress = min(max((zoom - startZoom) / (clampedEndZoom - startZoom), 0), 1)
            return clampedExtensionAngle * Float(progress)
        }
    }

    public struct PresentationSettings: Equatable, Sendable {
        public var automaticTransitionStartZoom: Double
        public var automaticTransitionSpan: Double
        public var globeRadiusScale: Double

        public init(automaticTransitionStartZoom: Double,
                    automaticTransitionSpan: Double,
                    globeRadiusScale: Double) {
            self.automaticTransitionStartZoom = automaticTransitionStartZoom
            self.automaticTransitionSpan = automaticTransitionSpan
            self.globeRadiusScale = globeRadiusScale
        }
    }

    public struct TileSettings: Equatable, Sendable {
        public struct CoverageSettings: Equatable, Sendable {
            public var maximumZoomLevel: Int

            public init(maximumZoomLevel: Int) {
                self.maximumZoomLevel = maximumZoomLevel
            }
        }

        public struct NetworkSettings: Equatable, Sendable {
            public enum AuthorizationMode: Equatable, Sendable {
                case bearerHeader
                case accessTokenQuery(parameterName: String)
            }

            public var maxConcurrentFetches: Int
            public var pendingRequestQueueCapacity: Int
            public var tileBaseURL: URL
            /// Optional TileJSON endpoint. When set, the tile loader discovers a
            /// versioned, immutable URL template (…/v/<version>/tiles/{z}/{x}/{y}.pbf)
            /// and falls back to `tileBaseURL/{z}/{x}/{y}.mvt` until/if it resolves.
            public var tileJSONURL: URL?
            public var authorizationToken: String?
            public var authorizationMode: AuthorizationMode
            /// Provider `configurationFingerprint`, folded into the raw and prepared
            /// disk-cache namespaces so a provider/content change invalidates the
            /// caches even when the base URL is unchanged (e.g. a server-side layer
            /// was added). 0 means "not provider-derived".
            public var cacheIdentity: UInt64

            public init(maxConcurrentFetches: Int,
                        pendingRequestQueueCapacity: Int,
                        tileBaseURL: URL = URL(string: "https://example.com/api/v1/map/tiles")!,
                        tileJSONURL: URL? = nil,
                        authorizationToken: String? = nil,
                        authorizationMode: AuthorizationMode = .bearerHeader,
                        cacheIdentity: UInt64 = 0) {
                self.maxConcurrentFetches = maxConcurrentFetches
                self.pendingRequestQueueCapacity = pendingRequestQueueCapacity
                self.tileBaseURL = tileBaseURL
                self.tileJSONURL = tileJSONURL
                self.authorizationToken = authorizationToken
                self.authorizationMode = authorizationMode
                self.cacheIdentity = cacheIdentity
            }
        }

        public struct CacheSettings: Equatable, Sendable {
            public static let defaultPreparedDiskCacheSizeInBytes: Int = 256 * 1_024 * 1_024

            public var clearDiskCachesOnLaunch: Bool
            /// Raw HTTP tile cache (URLSession's URLCache). When false, every tile
            /// download goes to the network (still revalidated by the server ETag).
            public var urlCacheEnabled: Bool
            /// On-disk cache of parsed/tessellated tiles. When false, tiles are
            /// re-parsed from the raw bytes on every load.
            public var preparedTileCacheEnabled: Bool
            public var preparedDiskTimeToLive: TimeInterval
            /// Root-wide byte quota for all prepared-tile format/style namespaces.
            /// The most recently initialized map/cache instance makes its quota
            /// the active root-wide policy.
            public var preparedDiskCacheSizeInBytes: Int
            public var memoryCacheSizeInBytes: Int

            public init(clearDiskCachesOnLaunch: Bool,
                        urlCacheEnabled: Bool = true,
                        preparedTileCacheEnabled: Bool = true,
                        preparedDiskTimeToLive: TimeInterval,
                        memoryCacheSizeInBytes: Int) {
                self.init(clearDiskCachesOnLaunch: clearDiskCachesOnLaunch,
                          urlCacheEnabled: urlCacheEnabled,
                          preparedTileCacheEnabled: preparedTileCacheEnabled,
                          preparedDiskTimeToLive: preparedDiskTimeToLive,
                          preparedDiskCacheSizeInBytes: Self.defaultPreparedDiskCacheSizeInBytes,
                          memoryCacheSizeInBytes: memoryCacheSizeInBytes)
            }

            public init(clearDiskCachesOnLaunch: Bool,
                        urlCacheEnabled: Bool = true,
                        preparedTileCacheEnabled: Bool = true,
                        preparedDiskTimeToLive: TimeInterval,
                        preparedDiskCacheSizeInBytes: Int,
                        memoryCacheSizeInBytes: Int) {
                self.clearDiskCachesOnLaunch = clearDiskCachesOnLaunch
                self.urlCacheEnabled = urlCacheEnabled
                self.preparedTileCacheEnabled = preparedTileCacheEnabled
                self.preparedDiskTimeToLive = preparedDiskTimeToLive
                self.preparedDiskCacheSizeInBytes = preparedDiskCacheSizeInBytes
                self.memoryCacheSizeInBytes = memoryCacheSizeInBytes
            }
        }

        public struct ParsingSettings: Equatable, Sendable {
            public var addTestBorders: Bool

            public init(addTestBorders: Bool) {
                self.addTestBorders = addTestBorders
            }
        }

        public var coverage: CoverageSettings
        public var network: NetworkSettings
        public var cache: CacheSettings
        public var parsing: ParsingSettings

        public init(coverage: CoverageSettings,
                    network: NetworkSettings,
                    cache: CacheSettings,
                    parsing: ParsingSettings) {
            self.coverage = coverage
            self.network = network
            self.cache = cache
            self.parsing = parsing
        }

        func resolvedCoverageZoomLevel(forCameraZoom cameraZoom: Double) -> Int {
            TileCoverageZoomPolicy.resolve(cameraZoom: cameraZoom,
                                           renderSurfaceMode: .flat,
                                           maximumZoomLevel: coverage.maximumZoomLevel).baseZoom
        }
    }

    public struct LabelSettings: Equatable, Sendable {
        public struct HouseNumberSettings: Equatable, Sendable {
            public var enabled: Bool
            public var minimumZoom: Int

            public init(enabled: Bool,
                        minimumZoom: Int) {
                self.enabled = enabled
                self.minimumZoom = minimumZoom
            }
        }

        public struct SettlementVisibilitySettings: Equatable, Sendable {
            public var capitalMaximumZoom: Int
            public var cityMaximumZoom: Int
            public var smallSettlementMaximumZoom: Int

            public init(capitalMaximumZoom: Int = 12,
                        cityMaximumZoom: Int = 12,
                        smallSettlementMaximumZoom: Int = 12) {
                self.capitalMaximumZoom = capitalMaximumZoom
                self.cityMaximumZoom = cityMaximumZoom
                self.smallSettlementMaximumZoom = smallSettlementMaximumZoom
            }
        }

        public struct LandmarkSettings: Equatable, Sendable {
            public var minimumZoom: Int

            public init(minimumZoom: Int = 15) {
                self.minimumZoom = minimumZoom
            }
        }

        public struct BaseSettings: Equatable, Sendable {
            public var gridCellSizePx: Float
            public var fadeInSeconds: TimeInterval
            public var fadeOutSeconds: TimeInterval

            public init(gridCellSizePx: Float,
                        fadeInSeconds: TimeInterval,
                        fadeOutSeconds: TimeInterval) {
                self.gridCellSizePx = gridCellSizePx
                self.fadeInSeconds = fadeInSeconds
                self.fadeOutSeconds = fadeOutSeconds
            }
        }

        public struct RoadSettings: Equatable, Sendable {
            public var gridCellSizePx: Float
            public var maxGlyphTurnRadians: Float

            public init(gridCellSizePx: Float,
                        maxGlyphTurnRadians: Float) {
                self.gridCellSizePx = gridCellSizePx
                self.maxGlyphTurnRadians = maxGlyphTurnRadians
            }
        }

        public var language: LabelLanguage
        public var fallbackPolicy: LabelFallbackPolicy
        public var houseNumbers: HouseNumberSettings
        public var settlementVisibility: SettlementVisibilitySettings
        public var landmarks: LandmarkSettings
        public var base: BaseSettings
        public var road: RoadSettings

        public init(language: LabelLanguage,
                    fallbackPolicy: LabelFallbackPolicy = .international,
                    houseNumbers: HouseNumberSettings,
                    settlementVisibility: SettlementVisibilitySettings = SettlementVisibilitySettings(),
                    landmarks: LandmarkSettings = LandmarkSettings(),
                    base: BaseSettings,
                    road: RoadSettings) {
            self.language = language
            self.fallbackPolicy = fallbackPolicy
            self.houseNumbers = houseNumbers
            self.settlementVisibility = settlementVisibility
            self.landmarks = landmarks
            self.base = base
            self.road = road
        }
    }

    public struct SpaceSettings: Equatable, Sendable {
        public var clearColor: SIMD4<Double>

        public init(clearColor: SIMD4<Double>) {
            self.clearColor = clearColor
        }
    }

    public struct StarfieldSettings: Equatable, Sendable {
        public var starCount: Int
        public var sizeMin: Float
        public var sizeMax: Float
        public var brightnessMin: Float
        public var brightnessMax: Float
        public var near: Float
        public var far: Float
        public var radiusScale: Float

        public init(starCount: Int,
                    sizeMin: Float,
                    sizeMax: Float,
                    brightnessMin: Float,
                    brightnessMax: Float,
                    near: Float,
                    far: Float,
                    radiusScale: Float) {
            self.starCount = starCount
            self.sizeMin = sizeMin
            self.sizeMax = sizeMax
            self.brightnessMin = brightnessMin
            self.brightnessMax = brightnessMax
            self.near = near
            self.far = far
            self.radiusScale = radiusScale
        }
    }

    public struct EarthSceneSettings: Equatable, Sendable {
        public struct NightLightsSettings: Equatable, Sendable {
            public var isEnabled: Bool
            /// Light contribution multiplier. Expected range: `0...1`.
            public var intensity: Float
            /// Positive normalized dot-product width used to fade across the terminator.
            public var terminatorFadeWidth: Float
            /// Optional manifest URL for server-hosted night-light tiles.
            public var tileManifestURL: URL?

            /// Creates night-lights settings.
            /// - Parameters:
            ///   - intensity: Light contribution multiplier in the expected range `0...1`.
            ///   - terminatorFadeWidth: Positive normalized dot-product fade width.
            public init(isEnabled: Bool = true,
                        intensity: Float = 1.0,
                        terminatorFadeWidth: Float = 0.18,
                        tileManifestURL: URL? = nil) {
                self.isEnabled = isEnabled
                self.intensity = intensity
                self.terminatorFadeWidth = terminatorFadeWidth
                self.tileManifestURL = tileManifestURL
            }
        }

        public struct SunSettings: Equatable, Sendable {
            public var isEnabled: Bool
            /// Apparent disk angular size in shader-facing normalized units.
            public var diskAngularSize: Float
            /// Disk contribution multiplier. Expected range: `0...1`.
            public var diskIntensity: Float
            /// Surrounding glow contribution multiplier. Expected range: `0...1`.
            public var glowIntensity: Float
            /// Viewport-edge glare contribution multiplier. Expected range: `0...1`.
            /// Defaults to zero so offscreen Sun direction is not emphasized at the viewport edge.
            public var edgeGlareIntensity: Float
            /// Globe limb halo contribution multiplier. Expected range: `0...1`.
            public var limbHaloIntensity: Float
            /// Positive normalized width used to fade the globe limb halo.
            public var limbHaloWidth: Float

            /// Creates visible Sun settings.
            /// - Parameters:
            ///   - diskAngularSize: Apparent disk angular size in shader-facing normalized units.
            ///   - diskIntensity: Disk contribution multiplier in the expected range `0...1`.
            ///   - glowIntensity: Surrounding glow contribution multiplier in the expected range `0...1`.
            ///   - edgeGlareIntensity: Viewport-edge glare contribution multiplier in the expected range `0...1`.
            ///   - limbHaloIntensity: Globe limb halo contribution multiplier in the expected range `0...1`.
            ///   - limbHaloWidth: Positive normalized globe limb halo fade width.
            public init(isEnabled: Bool = true,
                        diskAngularSize: Float = 0.075,
                        diskIntensity: Float = 1.0,
                        glowIntensity: Float = 0.75,
                        edgeGlareIntensity: Float = 0.0,
                        limbHaloIntensity: Float = 0.35,
                        limbHaloWidth: Float = 0.10) {
                self.isEnabled = isEnabled
                self.diskAngularSize = diskAngularSize
                self.diskIntensity = diskIntensity
                self.glowIntensity = glowIntensity
                self.edgeGlareIntensity = edgeGlareIntensity
                self.limbHaloIntensity = limbHaloIntensity
                self.limbHaloWidth = limbHaloWidth
            }
        }

        /// Controls the full Earth scene lighting package: visible Sun, planet terminator shading,
        /// night-side brightness, and night lights.
        public var isEnabled: Bool
        public var timeMode: EarthSceneTimeMode
        /// Minimum daylight brightness. Expected range: `0...1`.
        public var daySideMinimumBrightness: Float
        /// Night-side base brightness. Expected range: `0...1`.
        public var nightSideBrightness: Float
        /// Positive normalized dot-product width used to fade across the terminator.
        public var terminatorFadeWidth: Float
        public var nightLights: NightLightsSettings
        public var sun: SunSettings

        /// Creates Earth scene settings.
        /// - Parameters:
        ///   - isEnabled: Enables the full Sun, terminator shading, and night-lights package.
        ///   - daySideMinimumBrightness: Minimum daylight brightness in the expected range `0...1`.
        ///   - nightSideBrightness: Night-side base brightness in the expected range `0...1`.
        ///   - terminatorFadeWidth: Positive normalized dot-product fade width.
        public init(isEnabled: Bool = true,
                    timeMode: EarthSceneTimeMode = .realtime,
                    daySideMinimumBrightness: Float = 0.82,
                    nightSideBrightness: Float = 0.18,
                    terminatorFadeWidth: Float = 0.12,
                    nightLights: NightLightsSettings = NightLightsSettings(),
                    sun: SunSettings = SunSettings()) {
            self.isEnabled = isEnabled
            self.timeMode = timeMode
            self.daySideMinimumBrightness = daySideMinimumBrightness
            self.nightSideBrightness = nightSideBrightness
            self.terminatorFadeWidth = terminatorFadeWidth
            self.nightLights = nightLights
            self.sun = sun
        }
    }

    public struct SceneSettings: Equatable, Sendable {
        public var mapClearColor: SIMD4<Double>
        public var space: SpaceSettings
        public var starfield: StarfieldSettings
        public var earth: EarthSceneSettings

        public init(mapClearColor: SIMD4<Double>,
                    space: SpaceSettings,
                    starfield: StarfieldSettings,
                    earth: EarthSceneSettings = EarthSceneSettings()) {
            self.mapClearColor = mapClearColor
            self.space = space
            self.starfield = starfield
            self.earth = earth
        }
    }

    public struct StyleSettings: Equatable, Sendable {
        /// How flat-mode extruded buildings are composited over the map.
        public enum BuildingExtrusionMode: String, Codable, Sendable {
            /// Buildings are blended over the map using `buildingExtrusionAlpha`.
            case translucent
            /// Buildings are fully opaque; `buildingExtrusionAlpha` and the
            /// style color alpha are ignored.
            case solid
        }

        public struct BaseColors: Equatable, Sendable {
            public var tileBackground: SIMD4<Float>
            public var globeBackground: SIMD4<Double>
            public var water: SIMD4<Float>
            public var landCover: SIMD4<Float>

            public init(tileBackground: SIMD4<Float>,
                        globeBackground: SIMD4<Double>,
                        water: SIMD4<Float>,
                        landCover: SIMD4<Float>) {
                self.tileBackground = tileBackground
                self.globeBackground = globeBackground
                self.water = water
                self.landCover = landCover
            }
        }

        public var preparedTileStyleRevision: UInt32
        public var flatSeparateRoadRenderingMinimumZoom: Int
        public var buildingExtrusionAlpha: Float
        public var buildingExtrusionMode: BuildingExtrusionMode
        public var fallbackFeatureColor: SIMD4<Float>
        public var baseColors: BaseColors

        public init(preparedTileStyleRevision: UInt32,
                    flatSeparateRoadRenderingMinimumZoom: Int,
                    buildingExtrusionAlpha: Float,
                    buildingExtrusionMode: BuildingExtrusionMode = .translucent,
                    fallbackFeatureColor: SIMD4<Float>,
                    baseColors: BaseColors) {
            self.preparedTileStyleRevision = preparedTileStyleRevision
            self.flatSeparateRoadRenderingMinimumZoom = flatSeparateRoadRenderingMinimumZoom
            self.buildingExtrusionAlpha = buildingExtrusionAlpha
            self.buildingExtrusionMode = buildingExtrusionMode
            self.fallbackFeatureColor = fallbackFeatureColor
            self.baseColors = baseColors
        }
    }

    public struct DebugSettings: Equatable, Sendable {
        public var enableDebugPanel: Bool
        public var coordinateScale: Float
        public var diagnosticsScale: Float
        public var leftPadding: Float
        public var topPadding: Float
        public var sectionSpacing: Float
        public var textColor: SIMD3<Float>

        public init(enableDebugPanel: Bool,
                    coordinateScale: Float,
                    diagnosticsScale: Float,
                    leftPadding: Float,
                    topPadding: Float,
                    sectionSpacing: Float,
                    textColor: SIMD3<Float>) {
            self.enableDebugPanel = enableDebugPanel
            self.coordinateScale = coordinateScale
            self.diagnosticsScale = diagnosticsScale
            self.leftPadding = leftPadding
            self.topPadding = topPadding
            self.sectionSpacing = sectionSpacing
            self.textColor = textColor
        }
    }

    public struct PostProcessingSettings: Equatable, Sendable {
        public var fxaaEnabled: Bool

        public init(fxaaEnabled: Bool = false) {
            self.fxaaEnabled = fxaaEnabled
        }
    }

    public struct AttributionSettings: Equatable, Sendable {
        public var isVisible: Bool
        public var title: String
        public var copyright: String
        public var linkURL: URL?

        public init(isVisible: Bool = true,
                    title: String = "Immersive map",
                    copyright: String = "© 2025-2026 ImmersiveMap contributors",
                    linkURL: URL? = URL(string: "https://x.com/BobkinArtem")) {
            self.isVisible = isVisible
            self.title = title
            self.copyright = copyright
            self.linkURL = linkURL
        }
    }

    public struct AvatarSettings: Equatable, Sendable {
        public enum Size: Int, Equatable, Sendable {
            case px64 = 64
            case px128 = 128
            case px256 = 256
            case px512 = 512
            case px1024 = 1024
            case px2048 = 2048
        }

        public var size: Size
        public var sizeScale: Float
        public var compressedScale: Float
        public var atlasSizePx: Int
        public var atlasPagesMax: Int
        public var borderWidthPx: Float
        public var borderColor: SIMD4<Float>
        public var beamColor: SIMD4<Float>
        public var collisionPaddingPx: Float
        public var groupingThreshold: Int
        public var maxOffsetPx: Float
        public var collisionIterations: Int
        public var springK: Float
        public var smoothing: Float

        public init(size: Size,
                    sizeScale: Float,
                    compressedScale: Float,
                    atlasSizePx: Int,
                    atlasPagesMax: Int,
                    borderWidthPx: Float,
                    borderColor: SIMD4<Float>,
                    beamColor: SIMD4<Float>,
                    collisionPaddingPx: Float,
                    groupingThreshold: Int,
                    maxOffsetPx: Float,
                    collisionIterations: Int,
                    springK: Float,
                    smoothing: Float) {
            self.size = size
            self.sizeScale = sizeScale
            self.compressedScale = compressedScale
            self.atlasSizePx = atlasSizePx
            self.atlasPagesMax = atlasPagesMax
            self.borderWidthPx = borderWidthPx
            self.borderColor = borderColor
            self.beamColor = beamColor
            self.collisionPaddingPx = collisionPaddingPx
            self.groupingThreshold = groupingThreshold
            self.maxOffsetPx = maxOffsetPx
            self.collisionIterations = collisionIterations
            self.springK = springK
            self.smoothing = smoothing
        }
    }

    public var renderLoop: RenderLoopSettings
    public var camera: CameraSettings
    public var presentation: PresentationSettings
    public var tileProvider: AnyImmersiveMapTileProvider
    public var mapStyle: AnyImmersiveMapMapStyle
    public var tiles: TileSettings
    public var labels: LabelSettings
    public var scene: SceneSettings
    public var style: StyleSettings
    public var avatars: AvatarSettings
    public var attribution: AttributionSettings
    public var postProcessing: PostProcessingSettings
    public var debug: DebugSettings

    public init(renderLoop: RenderLoopSettings,
                camera: CameraSettings,
                presentation: PresentationSettings,
                tileProvider: AnyImmersiveMapTileProvider = AnyImmersiveMapTileProvider(ImmersiveMapTilesProvider()),
                mapStyle: AnyImmersiveMapMapStyle = AnyImmersiveMapMapStyle(ImmersiveMapTilesMapStyle()),
                tiles: TileSettings,
                labels: LabelSettings,
                scene: SceneSettings,
                style: StyleSettings,
                avatars: AvatarSettings,
                attribution: AttributionSettings = AttributionSettings(),
                postProcessing: PostProcessingSettings = PostProcessingSettings(),
                debug: DebugSettings) {
        self.renderLoop = renderLoop
        self.camera = camera
        self.presentation = presentation
        self.tileProvider = tileProvider
        self.mapStyle = mapStyle
        self.tiles = tiles
        self.labels = labels
        self.scene = scene
        self.style = style
        self.avatars = avatars
        self.attribution = attribution
        self.postProcessing = postProcessing
        self.debug = debug
    }

    public static let `default` = ImmersiveMapSettings(
        renderLoop: RenderLoopSettings(forceContinuousRendering: false,
                                       interactionFramesPerSecond: 60,
                                       labelFadeFramesPerSecond: 30),
        camera: CameraSettings(maximumPitch: Float.pi * 5.0 / 12.0,
                               maximumZoom: 20.0,
                               focusedMarkerZoom: 15.25,
                               globeMinimumAbsoluteBearing: Float.pi / 12.0,
                               globeBearingUnlockZoom: 6.0,
                               globePitchUnlockZoom: 3.0,
                               highZoomPitchExtension: 0,
                               highZoomPitchExtensionStartZoom: 15.0,
                               highZoomPitchExtensionEndZoom: 16.0,
                               extraHighZoomPitchExtension: 0,
                               extraHighZoomPitchExtensionStartZoom: 18.4,
                               extraHighZoomPitchExtensionEndZoom: 20.0,
                               gesturePanTranslationScale: 0.1,
                               worldPanSensitivity: 0.05,
                               worldPanSpeed: 0.5,
                               pinchZoomFactor: 0.4,
                               pinchZoomVelocityFactor: 0.2,
                               pinchZoomVelocityLimit: 8.0,
                               dragZoomFactor: 2.0,
                               dragZoomVelocityFactor: 0.35,
                               dragZoomVelocityLimit: 5.0,
                               rotationGestureSensitivity: -0.6,
                               globePanInertiaEnabled: true,
                               globePanInertiaHalfLife: 0.28,
                               globePanInertiaActivationVelocity: 450.0,
                               globePanInertiaStopVelocity: 60.0,
                               globePanInertiaMaxInitialVelocity: 7000.0),
        presentation: PresentationSettings(automaticTransitionStartZoom: 6.0,
                                           automaticTransitionSpan: 1.0,
                                           globeRadiusScale: 0.14),
        tileProvider: AnyImmersiveMapTileProvider(ImmersiveMapTilesProvider()),
        mapStyle: AnyImmersiveMapMapStyle(ImmersiveMapTilesMapStyle()),
        tiles: TileSettings(coverage: TileSettings.CoverageSettings(maximumZoomLevel: ImmersiveMapTilesProvider.defaultMaximumTileZoomLevel),
                            network: TileSettings.NetworkSettings(maxConcurrentFetches: 5,
                                                                  pendingRequestQueueCapacity: 50,
                                                                  tileBaseURL: ImmersiveMapTilesProvider.defaultTileBaseURL,
                                                                  tileJSONURL: ImmersiveMapTilesProvider.defaultTileJSONURL,
                                                                  authorizationMode: .bearerHeader,
                                                                  cacheIdentity: ImmersiveMapTilesProvider().configurationFingerprint),
                            cache: TileSettings.CacheSettings(clearDiskCachesOnLaunch: false,
                                                              preparedDiskTimeToLive: 7 * 24 * 60 * 60,
                                                              memoryCacheSizeInBytes: 512 * 1024 * 1024),
                            parsing: TileSettings.ParsingSettings(addTestBorders: false)),
        labels: LabelSettings(language: .english,
                              fallbackPolicy: .international,
                              houseNumbers: LabelSettings.HouseNumberSettings(enabled: true,
                                                                              minimumZoom: 15),
                              settlementVisibility: LabelSettings.SettlementVisibilitySettings(capitalMaximumZoom: 12,
                                                                                               cityMaximumZoom: 12,
                                                                                               smallSettlementMaximumZoom: 12),
                              landmarks: LabelSettings.LandmarkSettings(minimumZoom: 15),
                              base: LabelSettings.BaseSettings(gridCellSizePx: 32.0,
                                                               fadeInSeconds: 0.15,
                                                               fadeOutSeconds: 0.25),
                              road: LabelSettings.RoadSettings(gridCellSizePx: 32.0,
                                                               maxGlyphTurnRadians: .pi / 6.0)),
        scene: SceneSettings(mapClearColor: SIMD4<Double>(1.0, 1.0, 1.0, 1.0),
                             space: SpaceSettings(clearColor: SIMD4<Double>(0.008, 0.012, 0.032, 1.0)),
                             starfield: StarfieldSettings(starCount: 3400,
                                                          sizeMin: 0.9,
                                                          sizeMax: 5.2,
                                                          brightnessMin: 0.16,
                                                          brightnessMax: 1.05,
                                                          near: 0.1,
                                                          far: 6000.0,
                                                          radiusScale: 10.5),
                             earth: EarthSceneSettings(nightLights: EarthSceneSettings.NightLightsSettings(isEnabled: false,
                                                                                                          tileManifestURL: ImmersiveMapTilesProvider.defaultNightLightsManifestURL))),
        style: StyleSettings(preparedTileStyleRevision: 85,
                             flatSeparateRoadRenderingMinimumZoom: 8,
                             buildingExtrusionAlpha: 0.6,
                             buildingExtrusionMode: .translucent,
                             fallbackFeatureColor: SIMD4<Float>(1.0, 0.0, 0.0, 1.0),
                             baseColors: StyleSettings.BaseColors(tileBackground: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                                                                  globeBackground: SIMD4<Double>(0.0039, 0.0431, 0.0980, 1.0),
                                                                  water: SIMD4<Float>(0.3, 0.6, 0.9, 1.0),
                                                                  landCover: SIMD4<Float>(0.4, 0.7, 0.4, 0.7))),
        avatars: AvatarSettings(size: .px64,
                                sizeScale: 1.7,
                                compressedScale: 0.55,
                                atlasSizePx: 4096,
                                atlasPagesMax: 1,
                                borderWidthPx: 3.0,
                                borderColor: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                                beamColor: SIMD4<Float>(0.65, 0.75, 1.0, 0.7),
                                collisionPaddingPx: 0.0,
                                groupingThreshold: 5,
                                maxOffsetPx: 220.0,
                                collisionIterations: 10,
                                springK: 0.25,
                                smoothing: 0.35),
        attribution: AttributionSettings(),
        postProcessing: PostProcessingSettings(fxaaEnabled: false),
        debug: DebugSettings(enableDebugPanel: false,
                             coordinateScale: 80.0,
                             diagnosticsScale: 60.0,
                             leftPadding: 100.0,
                             topPadding: 190.0,
                             sectionSpacing: 28.0,
                             textColor: SIMD3<Float>(0.82, 0.36, 0.0))
    )
}

public extension ImmersiveMapSettings {
    func renderLoopSettings(_ renderLoop: RenderLoopSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.renderLoop = renderLoop
        return settings
    }

    func cameraSettings(_ camera: CameraSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.camera = camera
        return settings
    }

    func presentationSettings(_ presentation: PresentationSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.presentation = presentation
        return settings
    }

    func tileProvider<P: ImmersiveMapTileProvider>(_ tileProvider: P) -> ImmersiveMapSettings {
        self.tileProvider(AnyImmersiveMapTileProvider(tileProvider))
    }

    func tileProvider(_ tileProvider: AnyImmersiveMapTileProvider) -> ImmersiveMapSettings {
        var settings = self
        settings.tileProvider = tileProvider
        settings.tiles.network.tileBaseURL = tileProvider.tileSource.tileBaseURL
        settings.tiles.network.tileJSONURL = tileProvider.tileSource.tileJSONURL
        settings.tiles.network.authorizationToken = tileProvider.tileSource.accessToken
        settings.tiles.network.authorizationMode = tileProvider.tileSource.authorization
        settings.tiles.network.cacheIdentity = tileProvider.configurationFingerprint
        if let maximumTileZoomLevel = tileProvider.maximumTileZoomLevel {
            settings.tiles.coverage.maximumZoomLevel = maximumTileZoomLevel
        }
        return settings
    }

    func mapStyle<S: ImmersiveMapMapStyle>(_ mapStyle: S) -> ImmersiveMapSettings {
        self.mapStyle(AnyImmersiveMapMapStyle(mapStyle))
    }

    func mapStyle(_ mapStyle: AnyImmersiveMapMapStyle) -> ImmersiveMapSettings {
        var settings = self
        settings.mapStyle = mapStyle
        return settings
    }

    func tileSettings(_ tiles: TileSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.tiles = tiles
        return settings
    }

    func tileSettings(clearDiskCachesOnLaunch: Bool? = nil,
                      urlCacheEnabled: Bool? = nil,
                      preparedTileCacheEnabled: Bool? = nil,
                      preparedDiskTimeToLive: TimeInterval? = nil,
                      memoryCacheSizeInBytes: Int? = nil) -> ImmersiveMapSettings {
        tileSettings(clearDiskCachesOnLaunch: clearDiskCachesOnLaunch,
                     urlCacheEnabled: urlCacheEnabled,
                     preparedTileCacheEnabled: preparedTileCacheEnabled,
                     preparedDiskTimeToLive: preparedDiskTimeToLive,
                     preparedDiskCacheSizeInBytes: nil,
                     memoryCacheSizeInBytes: memoryCacheSizeInBytes)
    }

    func tileSettings(clearDiskCachesOnLaunch: Bool? = nil,
                      urlCacheEnabled: Bool? = nil,
                      preparedTileCacheEnabled: Bool? = nil,
                      preparedDiskTimeToLive: TimeInterval? = nil,
                      preparedDiskCacheSizeInBytes: Int?,
                      memoryCacheSizeInBytes: Int? = nil) -> ImmersiveMapSettings {
        var settings = self
        if let clearDiskCachesOnLaunch {
            settings.tiles.cache.clearDiskCachesOnLaunch = clearDiskCachesOnLaunch
        }
        if let urlCacheEnabled {
            settings.tiles.cache.urlCacheEnabled = urlCacheEnabled
        }
        if let preparedTileCacheEnabled {
            settings.tiles.cache.preparedTileCacheEnabled = preparedTileCacheEnabled
        }
        if let preparedDiskTimeToLive {
            settings.tiles.cache.preparedDiskTimeToLive = preparedDiskTimeToLive
        }
        if let preparedDiskCacheSizeInBytes {
            settings.tiles.cache.preparedDiskCacheSizeInBytes = preparedDiskCacheSizeInBytes
        }
        if let memoryCacheSizeInBytes {
            settings.tiles.cache.memoryCacheSizeInBytes = memoryCacheSizeInBytes
        }
        return settings
    }

    func labelSettings(_ labels: LabelSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.labels = labels
        return settings
    }

    func sceneSettings(_ scene: SceneSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.scene = scene
        return settings
    }

    func earthScene(isEnabled: Bool = true) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.earth.isEnabled = isEnabled
        return settings
    }

    func nightLightsTileManifestURL(_ url: URL?) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.earth.nightLights.tileManifestURL = url
        return settings
    }

    func styleSettings(_ style: StyleSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.style = style
        return settings
    }

    func buildingExtrusionMode(_ mode: StyleSettings.BuildingExtrusionMode) -> ImmersiveMapSettings {
        var settings = self
        settings.style.buildingExtrusionMode = mode
        return settings
    }

    func avatarSettings(_ avatars: AvatarSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.avatars = avatars
        return settings
    }

    func avatarSettings(size: AvatarSettings.Size? = nil,
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
                        smoothing: Float? = nil) -> ImmersiveMapSettings {
        var avatars = self.avatars
        if let size {
            avatars.size = size
        }
        if let sizeScale {
            avatars.sizeScale = sizeScale
        }
        if let compressedScale {
            avatars.compressedScale = compressedScale
        }
        if let atlasSizePx {
            avatars.atlasSizePx = atlasSizePx
        }
        if let atlasPagesMax {
            avatars.atlasPagesMax = atlasPagesMax
        }
        if let borderWidthPx {
            avatars.borderWidthPx = borderWidthPx
        }
        if let borderColor {
            avatars.borderColor = borderColor
        }
        if let beamColor {
            avatars.beamColor = beamColor
        }
        if let collisionPaddingPx {
            avatars.collisionPaddingPx = collisionPaddingPx
        }
        if let groupingThreshold {
            avatars.groupingThreshold = groupingThreshold
        }
        if let maxOffsetPx {
            avatars.maxOffsetPx = maxOffsetPx
        }
        if let collisionIterations {
            avatars.collisionIterations = collisionIterations
        }
        if let springK {
            avatars.springK = springK
        }
        if let smoothing {
            avatars.smoothing = smoothing
        }
        return avatarSettings(avatars)
    }

    func attributionSettings(_ attribution: AttributionSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.attribution = attribution
        return settings
    }

    func postProcessingSettings(_ postProcessing: PostProcessingSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.postProcessing = postProcessing
        return settings
    }

    func debugSettings(_ debug: DebugSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.debug = debug
        return settings
    }

    func debugPanel(_ isEnabled: Bool = true) -> ImmersiveMapSettings {
        var settings = self
        settings.debug.enableDebugPanel = isEnabled
        return settings
    }

}
