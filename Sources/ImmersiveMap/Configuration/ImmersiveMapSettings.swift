// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

// The `Configuration` folder: the public settings and the small planner that
// classifies a settings change into the domains it touches. It describes
// intent and performs no runtime side effect: no controllers mutating render,
// tile, camera or UI state, no networking or secrets, no Metal, no tile
// parsing or label decisions. Defaults here are safe to publish.

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

        public var nameFieldSuffix: String {
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

    /// What a label shows when the feature has no name in the map's
    /// language.
    public enum LabelFallbackPolicy: String, Codable, Sendable {
        /// The English name, then the local name. When the map's language is
        /// written in Latin letters, a local name in Cyrillic, Greek,
        /// Armenian or Georgian is romanized to plain ASCII first, so the map
        /// shows one alphabet ("Georgiyevskiy Lane" for "Георгиевский
        /// переулок" on an English map). A local name in another script is
        /// shown as it is. When the map's language is written in Cyrillic,
        /// Greek, Armenian or Georgian, a local name in that alphabet comes
        /// before the English one ("Охотный Ряд", not "Okhotny Ryad", on a
        /// Russian map).
        case international
        /// The local name as the place spells it, then the English name.
        case localFirst
    }

    public struct RenderLoopSettings: Equatable, Sendable {
        public var forceContinuousRendering: Bool
        /// Requested frame rate while the map is interacting or animating, and
        /// whenever `forceContinuousRendering` keeps the loop running. On
        /// ProMotion displays the link is offered a range from this value up
        /// to 120 Hz, so supporting iPhone, iPad, and MacBook Pro panels
        /// animate at 120; on iPhone that additionally requires the host app
        /// to declare `CADisableMinimumFrameDurationOnPhone` in its
        /// Info.plist. Displays that cannot reach the requested rate clamp to
        /// their own maximum, and thermal pressure or Low Power Mode may cap
        /// the effective rate below this value
        /// (`RenderLoopPacing.PowerConstraintState`).
        public var interactionFramesPerSecond: Int
        /// Exact low-power cadence for label fade animations; it gets no
        /// ProMotion headroom.
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
        /// The invisible drag zones in the bottom corners that let one thumb drive
        /// the camera: pitch in the bottom leading corner, zoom in the bottom
        /// trailing one. Both are off by default, because a zone captures drags that
        /// would otherwise pan the map, and nothing on screen announces it, so an
        /// app opts in only when it wants one-handed camera control.
        /// Touch platforms only; ignored on macOS.
        public struct ControlZoneSettings: Equatable, Sendable {
            public var isPitchZoneEnabled: Bool
            public var isZoomZoneEnabled: Bool

            public init(isPitchZoneEnabled: Bool = false,
                        isZoomZoneEnabled: Bool = false) {
                self.isPitchZoneEnabled = isPitchZoneEnabled
                self.isZoomZoneEnabled = isZoomZoneEnabled
            }
        }

        /// A zoom-dependent rotation window for the globe: at zoom 0 the camera
        /// may turn at most `minimumAbsoluteBearing` away from north, and the
        /// window opens linearly to the full `maximumAbsoluteBearing` (or the
        /// half turn) at `unlockZoom`. Off unless an app sets one.
        public struct GlobeBearingLimit: Equatable, Sendable {
            public var minimumAbsoluteBearing: Float
            public var unlockZoom: Double

            public init(minimumAbsoluteBearing: Float, unlockZoom: Double) {
                self.minimumAbsoluteBearing = minimumAbsoluteBearing
                self.unlockZoom = unlockZoom
            }
        }

        /// Keeps a zoomed-out globe upright, north up and seen from straight
        /// above, so the planet is never left lying on its side. Across
        /// `zoomRange` the bearing and the pitch the camera may rest at close
        /// in linearly, from the camera's own limits at the upper bound to
        /// north up and the pitch floor at the lower bound and below it.
        ///
        /// It is a pull, not a wall. A camera outside what its zoom allows is
        /// eased back on every frame, during a gesture too, so zooming out of
        /// a turned and tilted view straightens the globe on the way, and a
        /// rotation past the allowed bearing springs back when the fingers
        /// let go. A tilt stops at the allowed pitch. A flight or a path
        /// follow owns the camera, and the pull waits for it to finish.
        /// The globe only: the flat map is never pulled.
        public struct GlobeUprightPull: Equatable, Sendable {
            /// The zooms over which the globe is straightened: upright at the
            /// lower bound and below it, free from the upper bound on.
            public var zoomRange: ClosedRange<Double>
            /// The seconds in which the pull closes half of what is left of
            /// the way back. Zero straightens at once.
            public var halfLife: Double

            public init(zoomRange: ClosedRange<Double> = 3...6,
                        halfLife: Double = 0.2) {
                self.zoomRange = zoomRange
                self.halfLife = halfLife
            }
        }

        /// A geographic region the camera is held to. Below the pull's zoom
        /// range the whole world is open, so a zoomed-out globe turns freely.
        /// Across the range the area the map center belongs in closes in on
        /// the region, following `pullCurve`, and from its upper bound it is
        /// the region itself. `edgeBehavior` says whether the edge of that
        /// area is a wall or an elastic band.
        public struct Bounds: Equatable, Sendable {
            /// What happens at the edge of the area the map center belongs in.
            public enum EdgeBehavior: Equatable, Sendable {
                /// The center cannot leave the area. Zooming in far from the
                /// region draws the center toward it as the area closes in.
                case hard
                /// The center may leave the area, and a pull draws it back on
                /// every frame, during gestures too, so a drag out of the
                /// area works against it and a pinch toward an unreachable
                /// point glides to the region as the zoom grows.
                ///
                /// The pull is gentle at the edge and grows with the distance:
                /// at `d` screen points out it closes half the gap every
                /// `pullHalfLife / (1 + d / maximumStretch)^pullProgression`
                /// seconds, and never faster than a sixteenth of
                /// `pullHalfLife`. A `pullProgression` of 0 pulls at the same
                /// rate at any distance, a larger one keeps the edge soft and
                /// the far field steep. A drag itself is also damped past the
                /// edge, the center stopping about `maximumStretch` points
                /// out however far the finger goes.
                case elastic(maximumStretch: Double = 200,
                             pullHalfLife: Double = 0.35,
                             pullProgression: Double = 2)
            }


            /// How far the pull has closed across its zoom range: a cubic
            /// Bezier from (0, 0) to (1, 1) with two control points, as in CSS
            /// `cubic-bezier()`. The x axis is the progress through the zoom
            /// range, the y axis the share of the way the reachable area has
            /// closed in on the region, 0 for the whole world and 1 for the
            /// region alone. A y outside 0...1 is clamped.
            public struct PullCurve: Equatable, Sendable {
                public var x1: Double
                public var y1: Double
                public var x2: Double
                public var y2: Double

                /// The control points' x values are clamped to 0...1, so the
                /// curve stays a function of the zoom.
                public init(x1: Double, y1: Double, x2: Double, y2: Double) {
                    self.x1 = min(max(x1, 0), 1)
                    self.y1 = y1
                    self.x2 = min(max(x2, 0), 1)
                    self.y2 = y2
                }

                /// Closes at a constant rate across the range.
                public static let linear = PullCurve(x1: 0, y1: 0, x2: 1, y2: 1)
                /// Starts gently and closes fastest at the upper bound.
                public static let easeIn = PullCurve(x1: 0.42, y1: 0, x2: 1, y2: 1)
                /// Closes fastest at the lower bound and settles onto the region.
                public static let easeOut = PullCurve(x1: 0, y1: 0, x2: 0.58, y2: 1)
                /// Gentle at both bounds, fastest in the middle.
                public static let easeInOut = PullCurve(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
            }

            /// The south-west corner, in degrees.
            public var southWest: GeoCoordinate
            /// The north-east corner, in degrees. A longitude west of the
            /// south-west one spans the antimeridian.
            public var northEast: GeoCoordinate
            /// The zooms over which the camera is drawn into the region: the
            /// whole world is open up to the lower bound, and the center is
            /// inside the region from the upper bound on. Equal bounds switch
            /// from one to the other at that zoom.
            public var pullZoomRange: ClosedRange<Double>
            /// How the pull runs across `pullZoomRange`.
            public var pullCurve: PullCurve
            /// A wall or an elastic band at the edge of the area, elastic by
            /// default.
            public var edgeBehavior: EdgeBehavior

            public init(southWest: GeoCoordinate,
                        northEast: GeoCoordinate,
                        pullZoomRange: ClosedRange<Double> = 1...2,
                        pullCurve: PullCurve = .easeInOut,
                        edgeBehavior: EdgeBehavior = .elastic()) {
                self.southWest = southWest
                self.northEast = northEast
                self.pullZoomRange = pullZoomRange
                self.pullCurve = pullCurve
                self.edgeBehavior = edgeBehavior
            }
        }

        /// The highest pitch the camera can reach, in radians from straight
        /// down: 85 degrees by default.
        public var maximumPitch: Float
        /// The lowest pitch the camera can reach, in radians from straight down.
        /// Zero (the default) allows the top-down view. A floor above the
        /// ceiling yields to it.
        public var minimumPitch: Float
        /// The lowest zoom the camera can reach. Gestures, zoom commands and
        /// camera flights are all clamped to it, so raising it keeps the map from
        /// ever showing the whole globe.
        public var minimumZoom: Double
        public var maximumZoom: Double
        public var focusedMarkerZoom: Double
        /// How far the camera may rotate away from north, in radians, symmetric
        /// around it; `nil` (the default) leaves rotation unbounded. The cap
        /// applies on both surfaces. With a `globeBearingLimit` the globe's
        /// window opens with zoom, and the cap becomes the widest that window
        /// opens instead of the full half turn.
        public var maximumAbsoluteBearing: Float?
        /// The globe's zoom-dependent rotation window, `nil` (the default)
        /// for none: the globe then turns as freely as the flat map.
        public var globeBearingLimit: GlobeBearingLimit?
        /// The pull that keeps a zoomed-out globe upright, on by default.
        /// `nil` turns it off: the globe then keeps any bearing and pitch at
        /// every zoom.
        public var globeUprightPull: GlobeUprightPull?
        /// The region the camera is held to, `nil` (the default) for the
        /// whole world.
        public var bounds: Bounds?
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
        /// How strongly zoom is anchored to the gesture point (cursor, pinch center, double tap):
        /// 1 keeps the world point under the cursor put, 0 zooms toward the screen center.
        public var zoomAnchorFactor: Double
        public var dragZoomFactor: Double
        public var dragZoomVelocityFactor: Double
        public var dragZoomVelocityLimit: Double
        public var rotationGestureSensitivity: Float
        /// How fast a tilt drag tilts: the multiple of the full pitch range
        /// that a drag across the whole view height sweeps. Applies to the
        /// two-finger vertical drag on touch platforms and to the tilt drag
        /// (right button, or Option-drag) on macOS; 1 makes a full-height
        /// drag exactly span the range, the default 2 reaches it in half.
        /// Dragging down tilts further and up levels off; a negative value
        /// inverts the direction, so -2 tilts on the way up at the same speed.
        public var tiltGestureSensitivity: Float
        public var globePanInertiaEnabled: Bool
        public var globePanInertiaHalfLife: Double
        public var globePanInertiaActivationVelocity: Double
        public var globePanInertiaStopVelocity: Double
        public var globePanInertiaMaxInitialVelocity: Double
        public var pitchFollowEnabled: Bool
        public var pitchFollowHalfLife: Double
        public var bearingFollowEnabled: Bool
        public var bearingFollowHalfLife: Double
        public var controlZones: ControlZoneSettings

        public init(maximumPitch: Float,
                    minimumPitch: Float = 0,
                    minimumZoom: Double = 0,
                    maximumZoom: Double,
                    focusedMarkerZoom: Double,
                    maximumAbsoluteBearing: Float? = nil,
                    globeBearingLimit: GlobeBearingLimit? = nil,
                    globeUprightPull: GlobeUprightPull? = GlobeUprightPull(),
                    bounds: Bounds? = nil,
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
                    tiltGestureSensitivity: Float = 2.0,
                    globePanInertiaEnabled: Bool = true,
                    globePanInertiaHalfLife: Double = 0.28,
                    globePanInertiaActivationVelocity: Double = 450.0,
                    globePanInertiaStopVelocity: Double = 60.0,
                    globePanInertiaMaxInitialVelocity: Double = 7000.0,
                    pitchFollowEnabled: Bool = true,
                    pitchFollowHalfLife: Double = 0.06,
                    bearingFollowEnabled: Bool = true,
                    bearingFollowHalfLife: Double = 0.06,
                    controlZones: ControlZoneSettings = ControlZoneSettings()) {
            self.maximumPitch = maximumPitch
            self.minimumPitch = minimumPitch
            self.minimumZoom = minimumZoom
            self.maximumZoom = maximumZoom
            self.focusedMarkerZoom = focusedMarkerZoom
            self.maximumAbsoluteBearing = maximumAbsoluteBearing
            self.globeBearingLimit = globeBearingLimit
            self.globeUprightPull = globeUprightPull
            self.bounds = bounds
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
            self.tiltGestureSensitivity = tiltGestureSensitivity
            self.globePanInertiaEnabled = globePanInertiaEnabled
            self.globePanInertiaHalfLife = globePanInertiaHalfLife
            self.globePanInertiaActivationVelocity = globePanInertiaActivationVelocity
            self.globePanInertiaStopVelocity = globePanInertiaStopVelocity
            self.globePanInertiaMaxInitialVelocity = globePanInertiaMaxInitialVelocity
            self.pitchFollowEnabled = pitchFollowEnabled
            self.pitchFollowHalfLife = pitchFollowHalfLife
            self.bearingFollowEnabled = bearingFollowEnabled
            self.bearingFollowHalfLife = bearingFollowHalfLife
            self.controlZones = controlZones
        }

        /// Clamps a zoom level to the configured range. Negative minimums are
        /// treated as zero (the whole world already fits at zoom 0), and an
        /// inverted range collapses to `maximumZoom`.
        func clampZoom(_ zoom: Double) -> Double {
            let lowerBound = max(minimumZoom, 0)
            guard lowerBound <= maximumZoom else {
                return maximumZoom
            }

            return min(max(zoom, lowerBound), maximumZoom)
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

        /// The pitch floor in force at a zoom: the configured minimum, but never
        /// above the ceiling that applies there, so an inverted range collapses
        /// to the ceiling instead of deadlocking the camera.
        func minimumReachablePitch(at zoom: Double) -> Float {
            min(max(minimumPitch, 0), maximumReachablePitch(at: zoom))
        }

        /// Clamps a pitch to the configured range at a zoom.
        func clampPitch(_ pitch: Float, at zoom: Double) -> Float {
            min(max(pitch, minimumReachablePitch(at: zoom)), maximumReachablePitch(at: zoom))
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

    /// Reuse of dismantled map views. When a SwiftUI screen with an
    /// `ImmersiveMapView` goes away, its platform view (renderer, GPU tile
    /// cache, text atlases) is parked for `parkedTimeToLive` seconds instead of
    /// being destroyed, and the next `ImmersiveMapView` adopts it warm. New
    /// settings are reconciled on adoption through the regular settings-apply
    /// path, so adopting with a different configuration is safe. An adopted
    /// view keeps its previous camera unless the new view provides an explicit
    /// camera position or an attached camera controller.
    public struct ViewReuseSettings: Equatable, Sendable {
        public var isEnabled: Bool
        public var parkedTimeToLive: TimeInterval

        public init(isEnabled: Bool = true,
                    parkedTimeToLive: TimeInterval = 30) {
            self.isEnabled = isEnabled
            self.parkedTimeToLive = parkedTimeToLive
        }
    }

    public struct PresentationSettings: Equatable, Sendable {
        public var automaticTransitionStartZoom: Double
        public var automaticTransitionSpan: Double
        public var globeRadiusScale: Double
        /// Whether the map is a globe at low zoom. On (the default), the
        /// world is a sphere until the camera zooms into the transition
        /// window and unrolls it into the plane. Off, the world is the
        /// Mercator plane at every zoom: no sphere, no morph, no stars, the
        /// flat map's sky and ground fog from zoom 0 up. Applies live.
        public var isGlobeEnabled: Bool

        public init(automaticTransitionStartZoom: Double,
                    automaticTransitionSpan: Double,
                    globeRadiusScale: Double,
                    isGlobeEnabled: Bool = true) {
            self.automaticTransitionStartZoom = automaticTransitionStartZoom
            self.automaticTransitionSpan = automaticTransitionSpan
            self.globeRadiusScale = globeRadiusScale
            self.isGlobeEnabled = isGlobeEnabled
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
            public var maxConcurrentFetches: Int
            public var pendingRequestQueueCapacity: Int
            /// The tile source: one PMTiles v3 archive over HTTP(S), read with
            /// range requests. The archive holds MVT tiles, gzip-compressed or
            /// not. A query string in the URL is sent as written, so a key can
            /// live there.
            public var tileArchiveURL: URL
            /// HTTP header fields added to every archive request. This is how
            /// header-based credentials travel, e.g. `["Authorization": "Bearer xxx"]`.
            public var tileRequestHeaders: [String: String]
            /// Folded into the raw and prepared disk-cache namespaces so a
            /// content change invalidates the caches even when the archive URL
            /// is unchanged. 0 means "not provider-derived".
            public var cacheIdentity: UInt64

            public init(maxConcurrentFetches: Int,
                        pendingRequestQueueCapacity: Int,
                        tileArchiveURL: URL = ImmersiveMapTilesService.tileArchiveURL,
                        tileRequestHeaders: [String: String] = [:],
                        cacheIdentity: UInt64 = 0) {
                self.maxConcurrentFetches = maxConcurrentFetches
                self.pendingRequestQueueCapacity = pendingRequestQueueCapacity
                self.tileArchiveURL = tileArchiveURL
                self.tileRequestHeaders = tileRequestHeaders
                self.cacheIdentity = cacheIdentity
            }
        }

        public struct CacheSettings: Equatable, Sendable {
            public static let defaultPreparedDiskCacheSizeInBytes: Int = 2 * 1_024 * 1_024 * 1_024

            public var clearDiskCachesOnLaunch: Bool
            /// URLSession's URLCache on the tile session. Inert with the
            /// archive source: it is read by byte range, and range answers
            /// bypass the cache. Kept as a setting so an app that toggled it
            /// still compiles and the planner still treats it as a cache
            /// change.
            public var urlCacheEnabled: Bool
            /// On-disk cache of parsed/tessellated tiles: the layer every tile
            /// the camera has already looked at comes back from, without the
            /// network. When false, tiles are re-parsed from the raw bytes on
            /// every load.
            public var preparedTileCacheEnabled: Bool
            /// LZFSE compression of prepared tiles before they hit the disk cache.
            /// When false, entries are written uncompressed: larger cache files in
            /// exchange for less CPU (and battery) burned while exploring new areas.
            /// Both variants stay readable regardless of this flag.
            public var preparedDiskCompressionEnabled: Bool
            public var preparedDiskTimeToLive: TimeInterval
            /// Root-wide byte quota for all prepared-tile format/style namespaces
            /// (2 GiB by default). The most recently initialized map/cache
            /// instance makes its quota the active root-wide policy. Tiles stay
            /// in GPU memory only while a frame draws them, so this quota
            /// decides how much of a revisited area comes back without a
            /// re-download and re-parse.
            public var preparedDiskCacheSizeInBytes: Int
            /// Backing storage of the deprecated `memoryCacheSizeInBytes`: kept
            /// so the public surface round-trips the value without the package
            /// itself touching a deprecated symbol.
            var legacyMemoryCacheSizeInBytes: Int

            @available(*, deprecated, message: "Has no effect: tiles stay in GPU memory only while a frame draws them, with no byte budget. Size the prepared disk cache instead: preparedDiskCacheSizeInBytes, or the preparedTileDiskCacheSize(bytes:) modifier.")
            public var memoryCacheSizeInBytes: Int {
                get { legacyMemoryCacheSizeInBytes }
                set { legacyMemoryCacheSizeInBytes = newValue }
            }

            /// - Parameter memoryCacheSizeInBytes: ignored; kept for source
            ///   compatibility (see the deprecated property of the same name).
            public init(clearDiskCachesOnLaunch: Bool,
                        urlCacheEnabled: Bool = true,
                        preparedTileCacheEnabled: Bool = true,
                        preparedDiskCompressionEnabled: Bool = true,
                        preparedDiskTimeToLive: TimeInterval,
                        memoryCacheSizeInBytes: Int) {
                self.init(clearDiskCachesOnLaunch: clearDiskCachesOnLaunch,
                          urlCacheEnabled: urlCacheEnabled,
                          preparedTileCacheEnabled: preparedTileCacheEnabled,
                          preparedDiskCompressionEnabled: preparedDiskCompressionEnabled,
                          preparedDiskTimeToLive: preparedDiskTimeToLive,
                          preparedDiskCacheSizeInBytes: Self.defaultPreparedDiskCacheSizeInBytes,
                          memoryCacheSizeInBytes: memoryCacheSizeInBytes)
            }

            /// - Parameter memoryCacheSizeInBytes: ignored; kept for source
            ///   compatibility (see the deprecated property of the same name).
            public init(clearDiskCachesOnLaunch: Bool,
                        urlCacheEnabled: Bool = true,
                        preparedTileCacheEnabled: Bool = true,
                        preparedDiskCompressionEnabled: Bool = true,
                        preparedDiskTimeToLive: TimeInterval,
                        preparedDiskCacheSizeInBytes: Int,
                        memoryCacheSizeInBytes: Int) {
                self.clearDiskCachesOnLaunch = clearDiskCachesOnLaunch
                self.urlCacheEnabled = urlCacheEnabled
                self.preparedTileCacheEnabled = preparedTileCacheEnabled
                self.preparedDiskCompressionEnabled = preparedDiskCompressionEnabled
                self.preparedDiskTimeToLive = preparedDiskTimeToLive
                self.preparedDiskCacheSizeInBytes = preparedDiskCacheSizeInBytes
                self.legacyMemoryCacheSizeInBytes = memoryCacheSizeInBytes
            }

            /// The deprecated `memoryCacheSizeInBytes` is left out on purpose:
            /// a no-op field must not make two settings unequal, or changing it
            /// would still recreate the renderer through
            /// `ImmersiveMapSettingsApplicationPlanner`.
            public static func == (lhs: CacheSettings, rhs: CacheSettings) -> Bool {
                lhs.clearDiskCachesOnLaunch == rhs.clearDiskCachesOnLaunch
                    && lhs.urlCacheEnabled == rhs.urlCacheEnabled
                    && lhs.preparedTileCacheEnabled == rhs.preparedTileCacheEnabled
                    && lhs.preparedDiskCompressionEnabled == rhs.preparedDiskCompressionEnabled
                    && lhs.preparedDiskTimeToLive == rhs.preparedDiskTimeToLive
                    && lhs.preparedDiskCacheSizeInBytes == rhs.preparedDiskCacheSizeInBytes
            }
        }

        public struct ParsingSettings: Equatable, Sendable {
            public var addTestBorders: Bool

            public init(addTestBorders: Bool) {
                self.addTestBorders = addTestBorders
            }
        }

        /// The flattened ground: the tiles of the deep zooms, which the
        /// camera blows up to many screens, carry their ground fills as
        /// one layer of triangles that do not overlap (`GroundFlattening`)
        /// instead of the layers a coarser tile stacks. Every pixel of such
        /// a tile's ground is one fill, so nothing has to be ordered in
        /// depth, which is what keeps the near ground whole at a street
        /// tilt, and no triangle crosses a cell of the grid, which keeps
        /// the mesh ready for a heightmap. Baked into the prepared tiles,
        /// so a change re-parses them.
        public struct GroundFlatteningSettings: Equatable, Sendable {
            /// The tile zoom the ground is flattened from, nil for never.
            /// A tile of this zoom or deeper is flattened whatever the
            /// camera's zoom, a coarser one keeps its layers.
            public var fromTileZoom: Int?
            /// The grid a flattened tile's triangles keep to, cells a side:
            /// no triangle crosses a cell. More cells, more triangles.
            /// Clamped to `1...256`.
            public var grid: Int

            public init(fromTileZoom: Int? = 15, grid: Int = 16) {
                self.fromTileZoom = fromTileZoom
                self.grid = grid
            }
        }

        /// How the tile loader uses regions downloaded through
        /// `ImmersiveMapOfflineController`. Serving needs no wiring beyond the
        /// mode: downloaded tiles are found on disk by the tile source
        /// identity the provider already carries.
        public struct OfflineSettings: Equatable, Sendable {
            public enum Mode: String, CaseIterable, Equatable, Sendable {
                /// Tiles come from the network; when a request fails (offline,
                /// server error, missing authorization), the downloaded
                /// regions answer instead.
                case automatic
                /// The network is never touched: only downloaded regions and
                /// the local caches render. Tiles outside every region stay
                /// empty.
                case offlineOnly
                /// Downloaded regions are ignored; failures render nothing,
                /// as if no region existed.
                case disabled
            }

            public var mode: Mode

            public init(mode: Mode = .automatic) {
                self.mode = mode
            }
        }

        /// The tiles drawn from a texture: a ring rule that names a raster
        /// size draws its tiles' ground from a texture of their fills,
        /// drawn once, kept on disk next to the prepared tiles and drawn
        /// from then on with its mipmaps (`RasterTileStore`). These are how
        /// much of it the GPU keeps, how fast new ones are made, and how
        /// they are sampled. The size is the rule's.
        public struct RasterizationSettings: Equatable, Sendable {
            /// What the textures the frame does not draw may hold in GPU
            /// memory before the longest unused leave: a camera that comes
            /// back finds them without reading the disk. The ones the frame
            /// draws stay whatever this says. Raise it for a map that pans
            /// back and forth over wide far rings, lower it on a device
            /// short of memory.
            public var memoryBudgetInBytes: Int
            /// How many textures are drawn from their tiles in one frame. A
            /// texture is drawn once, so this matters only the first time
            /// a camera crosses an area: more fills the far rings sooner,
            /// fewer keeps those frames short.
            public var bakesPerFrame: Int
            /// The anisotropic filtering of the textures, 1 to 16 samples.
            /// The far rings are seen almost edge on, where a texture
            /// without it blurs along the view. Lower it only on a GPU short
            /// of bandwidth.
            public var maximumAnisotropy: Int
            /// Added to the mip level the GPU picks: above 0 the far ground
            /// is softer and quieter, below 0 sharper and busier.
            public var mipLevelBias: Float

            public init(memoryBudgetInBytes: Int = 96 * 1_024 * 1_024,
                        bakesPerFrame: Int = 4,
                        maximumAnisotropy: Int = 16,
                        mipLevelBias: Float = 0) {
                self.memoryBudgetInBytes = memoryBudgetInBytes
                self.bakesPerFrame = bakesPerFrame
                self.maximumAnisotropy = maximumAnisotropy
                self.mipLevelBias = mipLevelBias
            }
        }

        public var coverage: CoverageSettings
        public var network: NetworkSettings
        public var cache: CacheSettings
        public var parsing: ParsingSettings
        public var groundFlattening: GroundFlatteningSettings
        public var offline: OfflineSettings
        public var rasterization: RasterizationSettings

        public init(coverage: CoverageSettings,
                    network: NetworkSettings,
                    cache: CacheSettings,
                    parsing: ParsingSettings,
                    offline: OfflineSettings = OfflineSettings(),
                    groundFlattening: GroundFlatteningSettings = GroundFlatteningSettings(),
                    rasterization: RasterizationSettings = RasterizationSettings()) {
            self.coverage = coverage
            self.network = network
            self.cache = cache
            self.parsing = parsing
            self.offline = offline
            self.groundFlattening = groundFlattening
            self.rasterization = rasterization
        }

        func resolvedCoverageZoomLevel(forCameraZoom cameraZoom: Double) -> Int {
            TileCoverageZoomPolicy.resolve(cameraZoom: cameraZoom,
                                           renderSurfaceMode: .flat,
                                           maximumZoomLevel: coverage.maximumZoomLevel).baseZoom
        }
    }

    public struct LabelSettings: Equatable, Sendable {
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
            /// Collision grid cell in layout points. In points rather than device
            /// pixels so that label density per unit of perceived screen area is
            /// the same on every display: in pixels, a 3x phone would pack 2.25
            /// times as many labels into a physically smaller screen.
            public var gridCellSizePoints: Float
            public var fadeInSeconds: TimeInterval
            public var fadeOutSeconds: TimeInterval
            /// The least clear space between two point labels, in layout
            /// points: a label is kept only where its box, grown by half of
            /// this on every side, meets no other. At zero the labels pack
            /// edge to edge and a busy street reads as one block of text.
            public var collisionSpacingPoints: Float
            /// How small a point label gets with distance on a tilted map,
            /// as a fraction of its size. A label keeps its size at the
            /// point the camera looks at and nearer, and shrinks with its
            /// distance beyond it (twice as far, half as big) down to this,
            /// so the labels toward the horizon recede with the map instead
            /// of lying over it like stickers. The collisions measure the
            /// shrunk labels. 1 keeps every label at its size. Read once,
            /// when the map is created, like the fades; the debug panel can
            /// move it while the map runs.
            public var perspectiveMinimumScale: Float
            /// How near the camera, in metres, the local detail shows: the
            /// labels the style marks local (`PointLabelStyle.isLocal`: the
            /// house numbers, the plaques, the offices), which also keep to
            /// the three by three tiles around the one the camera looks at.
            /// Measured from the camera to the label's anchor, so on a tilted
            /// map the detail at the foot of the frame shows and the detail
            /// up the street does not, whatever the zoom. On the flat map;
            /// on the globe the tiles alone decide. The debug panel can move
            /// it while the map runs.
            public var localDetailMaximumDistanceMeters: Float

            public init(gridCellSizePoints: Float,
                        fadeInSeconds: TimeInterval,
                        fadeOutSeconds: TimeInterval,
                        collisionSpacingPoints: Float = 10,
                        perspectiveMinimumScale: Float = 0.75,
                        localDetailMaximumDistanceMeters: Float = 400) {
                self.gridCellSizePoints = gridCellSizePoints
                self.fadeInSeconds = fadeInSeconds
                self.fadeOutSeconds = fadeOutSeconds
                self.collisionSpacingPoints = collisionSpacingPoints
                self.perspectiveMinimumScale = perspectiveMinimumScale
                self.localDetailMaximumDistanceMeters = localDetailMaximumDistanceMeters
            }
        }

        public struct RoadSettings: Equatable, Sendable {
            /// Collision grid cell in layout points, as for `BaseSettings`.
            public var gridCellSizePoints: Float
            public var maxGlyphTurnRadians: Float
            /// The camera zoom from which the extruded buildings and the scene
            /// models paint over the road names behind them, pixel by pixel,
            /// like any other thing behind a wall. Each letter stands where it
            /// touches its road: a wall behind the road leaves it whole, one in
            /// front of it cuts it. The names keep their place in the
            /// collisions and their fades. On the flat map only, and the frames
            /// that do it keep the world's depth for the label pass, one more
            /// full-screen depth texture. `.infinity` never paints over a road
            /// name. Read once, when the map is created, like the fades.
            public var hidesBehindBuildingsFromZoom: Float

            public init(gridCellSizePoints: Float,
                        maxGlyphTurnRadians: Float,
                        hidesBehindBuildingsFromZoom: Float = 16) {
                self.gridCellSizePoints = gridCellSizePoints
                self.maxGlyphTurnRadians = maxGlyphTurnRadians
                self.hidesBehindBuildingsFromZoom = hidesBehindBuildingsFromZoom
            }
        }

        /// Whether the map has labels at all: place names, points of
        /// interest and road names alike. Off, the parser
        /// bakes no text into the prepared tiles (no name resolution, no
        /// shaping, no glyph runs on the GPU), and with nothing to place
        /// the label layer and the per-frame placement and collision work
        /// behind it are skipped. Baked at parse time: toggling re-parses
        /// the tiles, like any other label setting. On by default.
        public var isEnabled: Bool
        public var language: LabelLanguage
        public var fallbackPolicy: LabelFallbackPolicy
        public var settlementVisibility: SettlementVisibilitySettings
        public var landmarks: LandmarkSettings
        public var base: BaseSettings
        public var road: RoadSettings

        public init(isEnabled: Bool = true,
                    language: LabelLanguage,
                    fallbackPolicy: LabelFallbackPolicy = .international,
                    settlementVisibility: SettlementVisibilitySettings = SettlementVisibilitySettings(),
                    landmarks: LandmarkSettings = LandmarkSettings(),
                    base: BaseSettings,
                    road: RoadSettings) {
            self.isEnabled = isEnabled
            self.language = language
            self.fallbackPolicy = fallbackPolicy
            self.settlementVisibility = settlementVisibility
            self.landmarks = landmarks
            self.base = base
            self.road = road
        }
    }

    public struct SpaceSettings: Equatable, Sendable {
        public var clearColor: SIMD4<Double>
        /// Leaves everything outside the globe unpainted, so whatever the app
        /// puts behind the map shows through: the frame is cleared to a fully
        /// transparent pixel and the starfield layer (space background, stars
        /// and the visible Sun) is not drawn at all. `clearColor` is ignored.
        /// The globe surface itself stays opaque, and the map of the flat
        /// presentation still covers the viewport with the style's map
        /// colour (`ImmersiveMapBaseColors.map`).
        public var isTransparent: Bool

        public init(clearColor: SIMD4<Double>,
                    isTransparent: Bool = false) {
            self.clearColor = clearColor
            self.isTransparent = isTransparent
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

    /// The static sun of the flat presentation: its direction defines where
    /// buildings and scene models cast their shadow-map shadows (there is no
    /// analytic surface shading; faces darken only via the shadow map).
    public struct SceneLightSettings: Equatable, Sendable {
        /// World-space direction pointing **towards** the light in the flat
        /// basis (+X east, +Y north, +Z up). Normalized before use.
        public var direction: SIMD3<Float>

        public init(direction: SIMD3<Float> = SIMD3<Float>(-0.4, -0.6, 1.0)) {
            self.direction = direction
        }
    }

    /// Directional shadows cast by extruded buildings and scene models onto
    /// the flat map, other buildings and models. Flat presentation only.
    public struct ShadowSettings: Equatable, Sendable {
        public var isEnabled: Bool
        /// Shadow darkening amount. Expected range: `0...1`.
        public var strength: Float
        /// Square shadow map side in pixels. Clamped to `256...4096` at render time.
        public var mapResolution: Int
        /// Coverage radius of the shadow map, measured in multiples of the
        /// camera distance, a quantity independent of pitch and bearing, so
        /// tilting or rotating the camera never changes shadow coverage or
        /// sharpness. Beyond the radius shadows fade out. There is one map
        /// stretched over the radius, so raising this coarsens every shadow in
        /// the frame in proportion, and `mapResolution` is what buys the
        /// density back. Clamped to `0.25...48`. Shadows fade out over the
        /// outer quarter of the radius, so the window's edge is never visible
        /// as a circle at any coverage. Values well under 1 are a debugging
        /// aid: they wind the window down onto the point the camera looks at,
        /// which is how the shadow map's texel grid is looked at up close.
        public var coverageCameraDistances: Float
        /// The least coverage radius of the shadow map, in meters, whatever
        /// `coverageCameraDistances` gives. Close to the ground the camera is
        /// a few tens of meters from the point it looks at, and a few camera
        /// distances end a few houses down the street: the floor keeps the
        /// shadows down the street the camera looks along. From a camera high
        /// over the map the camera distances are the larger and the floor
        /// does nothing. The window is fitted to the visible ground inside
        /// the radius, so the extra meters go to the ground in the frame.
        /// Zero turns the floor off. Clamped to `0...5000`.
        public var minimumCoverageMeters: Float
        /// Tallest building the shadow window is fitted for, in meters.
        /// Expected range: `10...500`, clamped at render time.
        ///
        /// The window has to reach beyond its own disc by
        /// `height * |L.xy| / L.z`, which is how far a caster of that height
        /// throws its shadow into the disc: under a midday sun about 0.72 of
        /// the height. That margin is added to the window whether or not a
        /// building that tall is anywhere in sight, and it is spent on texels.
        /// At a street camera with a 1000 m limit it was three quarters of the
        /// window, which is why coverage seemed to do nothing to the sharpness
        /// of a shadow's edge: it was moving the other quarter.
        ///
        /// Set it to the tallest building actually around, and the texels go
        /// to the shadows on screen. Set it too low and a building above it
        /// stops casting into the window at all.
        ///
        /// The default is the range's ceiling: every building casts its whole
        /// shadow into the window, a tower at the edge of the visible ground
        /// included, and the texels it costs are paid back by the 4K shadow
        /// map and the window's floor in meters (`minimumCoverageMeters`).
        /// A map of low buildings can lower it to the tallest one around for
        /// sharper shadows in a street view, where the margin is pure cost:
        /// the window is fitted to the visible ground anyway, and a taller
        /// limit only widens the rim that a caster standing at the window's
        /// edge would need.
        public var maxCasterHeightMeters: Float
        /// How far a receiver's shadow lookup steps off its own surface, along
        /// the surface normal, measured in shadow-map texels. Expected range:
        /// `0...8`, clamped at render time.
        ///
        /// This is the only defence against shadow acne (the striped
        /// self-shadowing on walls turned away from the sun), and it is a
        /// two-sided trade. Too little and grazing walls stripe; too much and
        /// the lookup steps out past real occluders, so a wall stops being
        /// shadowed by anything closer to it than the offset, which is what
        /// makes narrow alleys and light wells lose their shadows as the
        /// camera pulls back. The offset is stated in texels rather than in
        /// meters on purpose: the amount of acne to cover is proportional to
        /// how coarse the map is, so a texel-relative offset stays correct at
        /// every zoom and coverage.
        public var normalOffsetTexels: Float
        /// How soft the edge of a shadow is: the factor the sampling kernel's
        /// four taps are pushed out by. Expected range: `1...2.5`, clamped at
        /// render time. `1` is the plain 3x3 tent, and every step up widens
        /// the ramp in proportion.
        ///
        /// The default sits a step above the plain tent, which is where a
        /// shadow's edge stops reading as a hard cut without the contact under
        /// a building going soft.
        ///
        /// It costs nothing: the kernel is the same four hardware compares at
        /// any softness. And it cannot move a shadow, because the kernel stays
        /// symmetric about the point being shaded, which puts the half-lit
        /// contour on the true edge whatever the width; only the ramp around
        /// it gets longer.
        ///
        /// What it is not is a way to sharpen a stepped edge. The steps in a
        /// shadow's outline are one texel of the shadow map, and a wider
        /// kernel rounds their corners rather than removing them; the texel is
        /// what `mapResolution`, `coverageCameraDistances` and
        /// `maxCasterHeightMeters` decide between them. Raising softness far
        /// also softens the contact where a building meets the ground, which
        /// is what makes it read as standing on it.
        public var softness: Float
        /// The cast of the shadowed light, as an RGB multiplier applied on top
        /// of `strength` where a surface is fully in shadow: white keeps the
        /// neutral darkening, and the default cool tint gives shadows the
        /// bluish cast of light arriving only from the sky, which is what
        /// keeps a shadowed street reading as daylight rather than as a grey
        /// stain. Components run `0...1`; a partially shadowed fragment takes
        /// on the tint in proportion.
        public var tint: SIMD3<Float>

        public init(isEnabled: Bool = true,
                    strength: Float = 0.22,
                    mapResolution: Int = 4096,
                    coverageCameraDistances: Float = 3.0,
                    minimumCoverageMeters: Float = 500,
                    maxCasterHeightMeters: Float = 500,
                    normalOffsetTexels: Float = 2.5,
                    softness: Float = 1.5,
                    tint: SIMD3<Float> = SIMD3<Float>(0.88, 0.92, 1.0)) {
            self.isEnabled = isEnabled
            self.strength = strength
            self.mapResolution = mapResolution
            self.coverageCameraDistances = coverageCameraDistances
            self.minimumCoverageMeters = minimumCoverageMeters
            self.maxCasterHeightMeters = maxCasterHeightMeters
            self.normalOffsetTexels = normalOffsetTexels
            self.softness = softness
            self.tint = tint
        }
    }

    /// The globe's atmosphere: a halo of scattered light around the
    /// planet's limb and a matching glow on the surface toward it. Globe
    /// presentation only; through the globe-to-flat morph it fades into the
    /// flat map's fog band (which is always on and takes its colour from
    /// the style's map colour, `ImmersiveMapBaseColors.map`), and the flat
    /// map has no atmosphere.
    /// A thin glow at the limb that hides the tile mesh's edge stays even
    /// with the atmosphere off.
    public struct AtmosphereSettings: Equatable, Sendable {
        public var isEnabled: Bool
        /// The color of the scattered light, RGB in `0...1`. Sky blue by default;
        /// the very edge of the halo whitens toward the limb on its own.
        public var color: SIMD3<Float>
        /// Brightness multiplier of the halo and of the surface glow. Expected
        /// range: `0...2`; 1 is the designed look, 0 leaves the sphere bare
        /// while keeping the layer on.
        public var intensity: Float
        /// Width multiplier of the halo, relative to the globe radius: 1 is
        /// the full shell, 0.38 (the default) a thin bright ring hugging the
        /// limb, 2 twice the full shell. The
        /// halo scales with the globe on screen, so it looks the same at every
        /// zoom of the globe presentation.
        public var thickness: Float
        /// How much the scene light (`SceneLightSettings.direction`, the sun
        /// the buildings cast their shadows from) shapes the halo, `0...1`:
        /// at 1 the halo is full where the limb faces the light and dims to
        /// a residual glow opposite it; at 0 it is the same brightness all
        /// the way around.
        public var sunInfluence: Float

        public init(isEnabled: Bool = true,
                    color: SIMD3<Float> = SIMD3<Float>(0.40, 0.66, 1.0),
                    intensity: Float = 1.0,
                    thickness: Float = 0.38,
                    sunInfluence: Float = 0.44) {
            self.isEnabled = isEnabled
            self.color = color
            self.intensity = intensity
            self.thickness = thickness
            self.sunInfluence = sunInfluence
        }
    }

    /// The sky of the flat presentation: above the horizon line the sky, a
    /// short pale glow at the line that gives way to the sky colour within
    /// a few degrees, and below it a thin band of the ground whitening into
    /// the same colour at the line, which hides the seam between the far
    /// ground and the sky. On by default. Off, nothing is painted above the
    /// line (the sky is the map's clear colour) and the band whitens into
    /// that colour, so the far range still meets the sky with no seam. The
    /// far ground itself is veiled by the ground fog (`GroundFogSettings`),
    /// which takes its colour from `horizonColor`. The globe has its own
    /// treatment, `AtmosphereSettings`. Through the globe-to-flat morph the
    /// atmosphere hands over to this.
    public struct FogSettings: Equatable, Sendable {
        public var isEnabled: Bool
        /// The sky's colour away from the horizon, RGB in `0...1`.
        public var skyColor: SIMD3<Float>
        /// The colour at the horizon: the glow the sky brightens into over
        /// its last degrees coming down, the band at the line and, unless it
        /// states its own, the ground fog, so they all meet at the line in
        /// one colour. White by default, the way a hazy day's sky whitens
        /// toward the ground.
        public var horizonColor: SIMD3<Float>
        /// How wide the band at the horizon line is with the camera zoom:
        /// the ground whitening into the horizon colour over the last
        /// degrees under the line, which hides the seam between the far
        /// ground and the sky and is there with the fog off too. It is
        /// measured in degrees under the line, so from a camera high over
        /// the map it lies on the horizon, and from one standing in the
        /// street it reaches down the street to the camera's feet. A
        /// fade-out, say `.fadeOut(from: 18, to: 19)`, draws it in toward the
        /// line over that stretch of zoom, to `minimumHorizonBandShare` of
        /// its width from 19 on: a hairline that still hides the seam where
        /// the horizon is open. `.none` (the default) keeps it at its width
        /// at every zoom. Evaluated against the camera zoom each frame.
        public var horizonBandZoomFade: ImmersiveMapZoomFade

        /// The share of its width the horizon band keeps once
        /// `horizonBandZoomFade` has drawn it in.
        public static let minimumHorizonBandShare: Float = 0.1

        public init(isEnabled: Bool = true,
                    skyColor: SIMD3<Float> = SIMD3<Float>(0.40, 0.66, 1.0),
                    horizonColor: SIMD3<Float> = SIMD3<Float>(0.97, 0.97, 0.98),
                    horizonBandZoomFade: ImmersiveMapZoomFade = .none) {
            self.isEnabled = isEnabled
            self.skyColor = skyColor
            self.horizonColor = horizonColor
            self.horizonBandZoomFade = horizonBandZoomFade
        }

        /// The share of its width the band at the horizon line has at a
        /// camera zoom: 1 for `.none`, down to `minimumHorizonBandShare`
        /// where `horizonBandZoomFade` is out.
        func horizonBandShare(atZoom zoom: Double) -> Float {
            let alpha = min(max(horizonBandZoomFade.alpha(atZoom: zoom), 0), 1)
            return Self.minimumHorizonBandShare + (1 - Self.minimumHorizonBandShare) * alpha
        }
    }

    /// When the extruded buildings and the models of a model archive
    /// stand up out of the flat map.
    public struct ExtrusionSettings: Equatable, Sendable {
        /// The camera zoom the extruded buildings draw from. Below it the
        /// map is flat, and reaching it they rise out of the ground.
        public var buildingsMinimumZoom: Double
        /// How long a layer takes to rise out of the ground when the
        /// camera reaches its zoom. Zero stands it up at once. Leaving the
        /// zoom, the layer is gone at once. The extruded buildings grow
        /// from the ground to their height, the models of a model archive
        /// come up out of it whole, from `ModelArchiveSettings.minimumZoom`.
        public var riseSeconds: TimeInterval

        public init(buildingsMinimumZoom: Double = 15,
                    riseSeconds: TimeInterval = 0.6) {
            self.buildingsMinimumZoom = buildingsMinimumZoom
            self.riseSeconds = riseSeconds
        }
    }

    /// The fog that lies on the ground of the flat map and thins upward:
    /// thickest at the ground, its density falling by a factor of e every
    /// `heightMeters`, gathered along each view ray past
    /// `startDistanceMeters` from the camera. A far point low on the ground
    /// sinks in it, the near ground and everything high stays clear, and a
    /// tall building rises out of it. It veils the ground, the roads and the
    /// labels painted on the map, and the buildings and the models only
    /// with `veilsBuildings` on, so it hides the far detail and its shimmer
    /// and draws the eye to the near ground. On by default. The horizon's sky and the band at its line (`FogSettings`)
    /// are the horizon's own: either can be on without the other. The globe
    /// has none.
    ///
    /// Every length is in meters on the ground, so a fog layer 60 m high is
    /// 60 m high at every zoom, and a fog that begins 400 m from the camera
    /// begins there however close the camera is.
    ///
    /// Every value but the colour follows the camera zoom
    /// (`ImmersiveMapZoomCurve`), so the fog changes as the camera zooms
    /// rather than at a step. The lengths and the density run between their
    /// stops geometrically, the same ratio for every step of zoom, the way
    /// the map's own scale changes, so two stops a few zooms apart follow
    /// the map in between. A curve holds its first stop's value below it,
    /// so a fog meant to keep its look while the camera pulls away needs a
    /// stop at the lowest zoom it shows at, its lengths there scaled by two
    /// per zoom. The defaults: no fog up to zoom 8, coming in by zoom 10.
    /// From zoom 7 to 12 the zoom 12 look at the map's scale: at zoom 12 a
    /// thin haze from 40 km out, complete only toward the horizon some
    /// 200 km away, so the view still reaches far, and at zoom 7, 32 times
    /// as far, the same haze. At zoom 16 a fog from 400 m that is complete by
    /// 1.2 km, at the edge past which the buildings are drawn flat, 150 m
    /// high so the near towers rise out of it. At zoom 22, at the camera's
    /// feet, a low layer from 250 m, 60 m high: the street ahead is clear
    /// and the far bases sink softly into it. A single value states the same
    /// at every zoom.
    ///
    /// On a map with the globe the fog comes in over a tenth of the
    /// transition span (`PresentationSettings.automaticTransitionSpan`)
    /// past the zoom the globe's morph into the plane ends at, so it never
    /// appears at one frame. Applies live.
    public struct GroundFogSettings: Equatable, Sendable {
        public var isEnabled: Bool
        /// How thick the fog is at the ground, per kilometer: the share of
        /// light it takes over one kilometer there is about
        /// `1 - e^-density`. Raise it for a thicker fog, lower it for a
        /// veil. Past the start's softness the fog is complete within about
        /// `3 / density` kilometers along the ground.
        public var densityPerKilometer: ImmersiveMapZoomCurve
        /// How high the fog rises, in meters: its density falls by a factor
        /// of e every this many meters above the ground. Low, a layer the
        /// buildings stand out of. High, a haze that fills the view.
        public var heightMeters: ImmersiveMapZoomCurve
        /// How far from the camera the fog begins, in meters: nearer than
        /// this the view is clear.
        public var startDistanceMeters: ImmersiveMapZoomCurve
        /// How far past `startDistanceMeters` the fog takes to come in, in
        /// meters: its density rises smoothly from nothing to full over this
        /// stretch, so the veil has no edge where it begins. 0 starts it at
        /// full density at once. Widen it for a softer, longer transition
        /// from the clear near ground into the fog.
        public var startSoftnessMeters: ImmersiveMapZoomCurve
        /// The fog's colour at the horizon line, RGB in `0...1`. Nil takes
        /// the horizon's colour (`FogSettings.horizonColor`), so the fog
        /// meets the sky at the line in one colour. Above the line the fog
        /// takes the sky's colour in the direction of the view, where the
        /// horizon paints a sky (`FogSettings.isEnabled`): a building veiled
        /// in full is the sky behind it, not a pale block on it.
        public var color: SIMD3<Float>?
        /// The most the fog veils anything, `0...1`: under 1 the farthest
        /// ground still shows through, and at 0 there is no fog. The value
        /// to bring the fog in or out with the zoom.
        public var maximumOpacity: ImmersiveMapZoomCurve
        /// Whether the fog veils the extruded buildings and the models too.
        /// Off (the default) they always draw in their own colour, crisp
        /// against the fogged ground behind them. On, a far building sinks
        /// into the fog with the ground, taking the sky's colour above the
        /// horizon line, which reads as the building turning see-through.
        public var veilsBuildings: Bool

        public init(isEnabled: Bool = true,
                    densityPerKilometer: ImmersiveMapZoomCurve = [7: 0.0019, 12: 0.06, 16: 17, 22: 6],
                    heightMeters: ImmersiveMapZoomCurve = [7: 256_000, 12: 8000, 16: 150, 22: 60],
                    startDistanceMeters: ImmersiveMapZoomCurve = [7: 1_280_000, 12: 40_000, 16: 400, 22: 250],
                    startSoftnessMeters: ImmersiveMapZoomCurve = [7: 4_800_000, 12: 150_000, 16: 800, 22: 950],
                    color: SIMD3<Float>? = nil,
                    maximumOpacity: ImmersiveMapZoomCurve = [8: 0, 10: 1],
                    veilsBuildings: Bool = false) {
            self.isEnabled = isEnabled
            self.densityPerKilometer = densityPerKilometer
            self.heightMeters = heightMeters
            self.startDistanceMeters = startDistanceMeters
            self.startSoftnessMeters = startSoftnessMeters
            self.color = color
            self.maximumOpacity = maximumOpacity
            self.veilsBuildings = veilsBuildings
        }
    }

    public struct SceneSettings: Equatable, Sendable {
        public var space: SpaceSettings
        public var starfield: StarfieldSettings
        public var light: SceneLightSettings
        public var shadows: ShadowSettings
        public var atmosphere: AtmosphereSettings
        public var fog: FogSettings
        public var groundFog: GroundFogSettings
        public var extrusion: ExtrusionSettings

        public init(space: SpaceSettings,
                    starfield: StarfieldSettings,
                    light: SceneLightSettings = SceneLightSettings(),
                    shadows: ShadowSettings = ShadowSettings(),
                    atmosphere: AtmosphereSettings = AtmosphereSettings(),
                    fog: FogSettings = FogSettings(),
                    groundFog: GroundFogSettings = GroundFogSettings(),
                    extrusion: ExtrusionSettings = ExtrusionSettings()) {
            self.space = space
            self.starfield = starfield
            self.light = light
            self.shadows = shadows
            self.atmosphere = atmosphere
            self.fog = fog
            self.groundFog = groundFog
            self.extrusion = extrusion
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
        /// FXAA over the finished frame, off by default: the engine renders
        /// at one sample per pixel with the ground lines antialiased
        /// analytically in the tile shaders, and FXAA is the optional extra
        /// smoothing of geometry silhouettes (building edges most visibly),
        /// at the price of one fullscreen pass.
        public var fxaaEnabled: Bool
        /// Multisampling of the world pass: 1 (the default) renders one
        /// sample per pixel, 4 is MSAA 4x. The device decides what it can
        /// do; a count it does not support falls back to the largest one
        /// under it that it does. Unlike FXAA this is not a pass over the
        /// finished frame but four depth and colour samples per pixel of
        /// the whole world pass, which cleans geometry silhouettes
        /// (buildings, models) while the tile shaders still run once per
        /// pixel; the frame costs more in memory bandwidth and the overlay
        /// (labels, avatars) takes its own pass over the resolved image.
        /// Every pipeline state depends on it, so changing it recreates the
        /// renderer.
        public var multisampleCount: Int

        public init(fxaaEnabled: Bool = false,
                    multisampleCount: Int = 1) {
            self.fxaaEnabled = fxaaEnabled
            self.multisampleCount = multisampleCount
        }
    }

    /// Attribution badge settings. The default text comes from the tile provider:
    /// we credit whoever's data we display. Overriding it makes sense only when
    /// the app shows the source attribution elsewhere (its own "About" screen,
    /// a custom overlay) and the source's license permits that.
    public struct AttributionSettings: Equatable, Sendable {
        /// Badge size preset. Scales fonts, paddings, corner radius and the
        /// maximum badge width coherently; the concrete metrics live in the
        /// UI layer.
        public enum Size: String, CaseIterable, Equatable, Sendable {
            case small
            case regular
            case large
        }

        /// Where the badge sits inside the map view, inset by the safe area.
        /// Leading/trailing follow the view's layout direction.
        public enum Position: String, CaseIterable, Equatable, Sendable {
            case bottomTrailing
            case bottomLeading
            case topTrailing
            case topLeading
            case bottomCenter
            case topCenter
        }

        public var isVisible: Bool
        public var size: Size
        public var position: Position
        /// Distance in points between the badge and the view edges (applied
        /// after the safe area). 0, the default, pins the badge tightly into
        /// its corner; raise it to float the badge over the map.
        public var margin: Double
        /// Badge text color as RGBA in `0...1` (same convention as
        /// `AvatarSettings.borderColor`); `nil` keeps the default white.
        /// The copyright line renders at 76% of the given alpha.
        public var textColor: SIMD4<Float>?
        /// The app declares that it shows the data credit itself (its own
        /// overlay, an about screen). Suppresses the hidden-attribution
        /// warning; it does not change what the badge draws.
        public var isProvidedExternally: Bool
        public var attributionOverride: ImmersiveMapAttribution?

        public init(isVisible: Bool = true,
                    size: Size = .regular,
                    position: Position = .bottomTrailing,
                    margin: Double = 0,
                    textColor: SIMD4<Float>? = nil,
                    isProvidedExternally: Bool = false,
                    attributionOverride: ImmersiveMapAttribution? = nil) {
            self.isVisible = isVisible
            self.size = size
            self.position = position
            self.margin = margin
            self.textColor = textColor
            self.isProvidedExternally = isProvidedExternally
            self.attributionOverride = attributionOverride
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

    /// Where the 3D models of the map's buildings come from: one archive of
    /// model tiles, read tile by tile as the camera moves.
    ///
    /// The archive is a PMTiles v3 file whose tiles hold models and not map
    /// data: each zoom 14 tile carries every model whose origin lies in it,
    /// merged into one mesh ready for the GPU (the format is
    /// `ModelTileContents`), so a tile of models is one draw. It is requested on
    /// its own, apart from the map's tiles: the models of the tiles in view
    /// are loaded, each stands in for the map's own building once it is
    /// loaded, and the models of the tiles left behind are released when
    /// the memory budget is passed.
    public struct ModelArchiveSettings: Equatable, Sendable {
        public static let defaultMemoryBudgetInBytes: Int = 128 * 1_024 * 1_024
        public static let defaultDiskCacheSizeInBytes: Int = 512 * 1_024 * 1_024
        public static let defaultDepthBias: Float = 0.05
        public static let maximumDepthBias: Float = 0.25

        /// The archive, over HTTP(S) range requests or from disk for a file
        /// URL. A query string is sent as written, so a key can live there.
        public var archiveURL: URL
        /// HTTP header fields added to every archive request, for
        /// credentials that travel as headers.
        public var requestHeaders: [String: String]
        /// The GPU memory the loaded model tiles may hold. The tiles in view
        /// stay whatever they cost. The ones left behind stay too, for a
        /// quick return, until the total passes this budget, and then the
        /// longest unused go first.
        public var memoryBudgetInBytes: Int
        /// The byte quota of the model tiles kept on disk, where a tile
        /// seen before comes back from without the network.
        public var diskCacheSizeInBytes: Int
        /// How much nearer in depth than it stands a model is drawn, as a
        /// share of its distance from the camera: 0.05 draws a model two
        /// kilometres away as if it were a hundred metres closer. Its place on
        /// the screen does not change, only what it covers and is covered
        /// by.
        ///
        /// It puts a model over the map's own building it stands in for
        /// where the map could not leave that building out, as in the map
        /// tiles whose buildings are merged into groups: the building
        /// reaches a little out of the model, by less than the bias takes
        /// the model forward. A building standing well in front of the
        /// model is nearer than that and still covers it. The cost of a
        /// larger share is a model showing over a neighbour that stands
        /// right before it. Zero draws a model where it stands. Kept
        /// within 0...`maximumDepthBias`.
        public var depthBias: Float {
            didSet { depthBias = Self.clampedDepthBias(depthBias) }
        }
        /// The camera zoom the models draw from. Below it they are not
        /// drawn and stand in for no building, and reaching it they rise
        /// out of the ground (`ExtrusionSettings.riseSeconds`). The model
        /// tiles are of zoom 14, so a zoom below that draws none whatever
        /// this says.
        public var minimumZoom: Double

        public init(archiveURL: URL,
                    requestHeaders: [String: String] = [:],
                    memoryBudgetInBytes: Int = ModelArchiveSettings.defaultMemoryBudgetInBytes,
                    diskCacheSizeInBytes: Int = ModelArchiveSettings.defaultDiskCacheSizeInBytes,
                    depthBias: Float = ModelArchiveSettings.defaultDepthBias,
                    minimumZoom: Double = 14) {
            self.archiveURL = archiveURL
            self.requestHeaders = requestHeaders
            self.memoryBudgetInBytes = memoryBudgetInBytes
            self.diskCacheSizeInBytes = diskCacheSizeInBytes
            self.depthBias = Self.clampedDepthBias(depthBias)
            self.minimumZoom = minimumZoom
        }

        private static func clampedDepthBias(_ value: Float) -> Float {
            value.isFinite ? min(max(value, 0), maximumDepthBias) : 0
        }
    }

    public var renderLoop: RenderLoopSettings
    public var camera: CameraSettings
    public var presentation: PresentationSettings
    public var mapStyle: AnyImmersiveMapMapStyle
    public var tiles: TileSettings
    public var labels: LabelSettings
    public var scene: SceneSettings
    public var avatars: AvatarSettings
    public var attribution: AttributionSettings
    public var postProcessing: PostProcessingSettings
    public var viewReuse: ViewReuseSettings
    public var debug: DebugSettings
    /// Models that take the place of the map's own buildings, see
    /// `ImmersiveMapLandmark`.
    public var landmarks: [ImmersiveMapLandmark]
    /// The archive the map loads building models from by tile, nil for a
    /// map without one. See `ModelArchiveSettings`.
    public var modelArchive: ModelArchiveSettings?

    public init(renderLoop: RenderLoopSettings,
                camera: CameraSettings,
                presentation: PresentationSettings,
                mapStyle: AnyImmersiveMapMapStyle = AnyImmersiveMapMapStyle(ProtomapsBasemapMapStyle()),
                tiles: TileSettings,
                labels: LabelSettings,
                scene: SceneSettings,
                avatars: AvatarSettings,
                attribution: AttributionSettings = AttributionSettings(),
                postProcessing: PostProcessingSettings = PostProcessingSettings(),
                viewReuse: ViewReuseSettings = ViewReuseSettings(),
                debug: DebugSettings,
                landmarks: [ImmersiveMapLandmark] = [],
                modelArchive: ModelArchiveSettings? = nil) {
        self.renderLoop = renderLoop
        self.camera = camera
        self.presentation = presentation
        self.mapStyle = mapStyle
        self.tiles = tiles
        self.labels = labels
        self.scene = scene
        self.avatars = avatars
        self.attribution = attribution
        self.postProcessing = postProcessing
        self.viewReuse = viewReuse
        self.debug = debug
        self.landmarks = landmarks
        self.modelArchive = modelArchive
    }

    public static let `default` = ImmersiveMapSettings(
        renderLoop: RenderLoopSettings(forceContinuousRendering: false,
                                       interactionFramesPerSecond: 60,
                                       labelFadeFramesPerSecond: 30),
        // Tilted nearly to the horizon, 85 degrees from straight down, on
        // both surfaces and at every zoom: a camera can look along the
        // streets at the skyline.
        camera: CameraSettings(maximumPitch: Float.pi * 17.0 / 36.0,
                               minimumZoom: 0.0,
                               // Two levels past the deepest tile: closer in,
                               // the tiles' detail is blown up past what it
                               // was drawn for. The flattened ground
                               // (`TileSettings.GroundFlatteningSettings`)
                               // keeps the near ground whole at any depth.
                               // A layered ground's rank depth holds a level
                               // past the tiles' zoom (Tile.metal): deeper, a
                               // street tilt can drop blocks of the near
                               // ground.
                               maximumZoom: 18.0,
                               focusedMarkerZoom: 15.25,
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
                               tiltGestureSensitivity: 2.0,
                               globePanInertiaEnabled: true,
                               globePanInertiaHalfLife: 0.28,
                               globePanInertiaActivationVelocity: 450.0,
                               globePanInertiaStopVelocity: 60.0,
                               globePanInertiaMaxInitialVelocity: 7000.0),
        presentation: PresentationSettings(automaticTransitionStartZoom: 6.0,
                                           automaticTransitionSpan: 1.0,
                                           globeRadiusScale: 0.14),
        mapStyle: AnyImmersiveMapMapStyle(ProtomapsBasemapMapStyle()),
        tiles: TileSettings(coverage: TileSettings.CoverageSettings(maximumZoomLevel: ImmersiveMapTilesService.maximumTileZoomLevel),
                            network: TileSettings.NetworkSettings(maxConcurrentFetches: 5,
                                                                  pendingRequestQueueCapacity: 50,
                                                                  tileArchiveURL: ImmersiveMapTilesService.tileArchiveURL,
                                                                  cacheIdentity: ImmersiveMapTilesService.cacheIdentity),
                            cache: TileSettings.CacheSettings(clearDiskCachesOnLaunch: false,
                                                              preparedDiskTimeToLive: 7 * 24 * 60 * 60,
                                                              memoryCacheSizeInBytes: 256 * 1024 * 1024),
                            parsing: TileSettings.ParsingSettings(addTestBorders: false)),
        labels: LabelSettings(language: .english,
                              fallbackPolicy: .international,
                              settlementVisibility: LabelSettings.SettlementVisibilitySettings(capitalMaximumZoom: 12,
                                                                                               cityMaximumZoom: 12,
                                                                                               smallSettlementMaximumZoom: 12),
                              landmarks: LabelSettings.LandmarkSettings(minimumZoom: 15),
                              base: LabelSettings.BaseSettings(gridCellSizePoints: 16.0,
                                                               fadeInSeconds: 0.15,
                                                               fadeOutSeconds: 0.25),
                              road: LabelSettings.RoadSettings(gridCellSizePoints: 16.0,
                                                               maxGlyphTurnRadians: .pi / 6.0)),
        scene: SceneSettings(space: SpaceSettings(clearColor: SIMD4<Double>(0.008, 0.012, 0.032, 1.0)),
                             starfield: StarfieldSettings(starCount: 3400,
                                                          sizeMin: 0.9,
                                                          sizeMax: 5.2,
                                                          brightnessMin: 0.16,
                                                          brightnessMax: 1.05,
                                                          near: 0.1,
                                                          far: 6000.0,
                                                          radiusScale: 10.5)),
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

    /// The globe at low zoom on or off; off keeps the map a plane at every
    /// zoom.
    func globe(isEnabled: Bool = true) -> ImmersiveMapSettings {
        var settings = self
        settings.presentation.isGlobeEnabled = isEnabled
        return settings
    }

    func viewReuseSettings(_ viewReuse: ViewReuseSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.viewReuse = viewReuse
        return settings
    }

    /// Points the tile loader at a PMTiles archive such as
    /// `https://tiles.example.com/planet.pmtiles`. `headers` are added to
    /// every archive request. The source is just bytes: how they are parsed
    /// and drawn is configured separately through `mapStyle(_:)`, and the
    /// zoom coverage through `tileMaximumZoomLevel(_:)` when the archive is
    /// built to a depth other than the default.
    func tileArchive(_ archiveURL: URL,
                     headers: [String: String] = [:]) -> ImmersiveMapSettings {
        var settings = self
        settings.tiles.network.tileArchiveURL = archiveURL
        settings.tiles.network.tileRequestHeaders = headers
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

    func landmarks(_ landmarks: [ImmersiveMapLandmark]) -> ImmersiveMapSettings {
        var settings = self
        settings.landmarks = landmarks
        return settings
    }

    /// Points the map at an archive of model tiles, keeping the budgets
    /// already set, and the depth bias too when `depthBias` is nil. See
    /// `ModelArchiveSettings`.
    func modelArchive(_ archiveURL: URL,
                      headers: [String: String] = [:],
                      depthBias: Float? = nil) -> ImmersiveMapSettings {
        var settings = self
        var archive = settings.modelArchive ?? ModelArchiveSettings(archiveURL: archiveURL)
        archive.archiveURL = archiveURL
        archive.requestHeaders = headers
        if let depthBias {
            archive.depthBias = depthBias
        }
        settings.modelArchive = archive
        return settings
    }

    /// The model archive in full, nil for a map without one.
    func modelArchiveSettings(_ modelArchive: ModelArchiveSettings?) -> ImmersiveMapSettings {
        var settings = self
        settings.modelArchive = modelArchive
        return settings
    }

    func tileSettings(_ tiles: TileSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.tiles = tiles
        return settings
    }

    /// The flattened ground's zoom and grid
    /// (`TileSettings.GroundFlatteningSettings`), a nil leaving a value as
    /// configured.
    func groundFlattening(fromTileZoom: Int? = nil, grid: Int? = nil) -> ImmersiveMapSettings {
        var settings = self
        if let fromTileZoom {
            settings.tiles.groundFlattening.fromTileZoom = fromTileZoom
        }
        if let grid {
            settings.tiles.groundFlattening.grid = grid
        }
        return settings
    }

    /// The tiles drawn from a texture (`TileSettings.RasterizationSettings`),
    /// a nil leaving a value as configured.
    func tileRasterization(memoryBudgetInBytes: Int? = nil,
                           bakesPerFrame: Int? = nil,
                           maximumAnisotropy: Int? = nil,
                           mipLevelBias: Float? = nil) -> ImmersiveMapSettings {
        var settings = self
        if let memoryBudgetInBytes {
            settings.tiles.rasterization.memoryBudgetInBytes = memoryBudgetInBytes
        }
        if let bakesPerFrame {
            settings.tiles.rasterization.bakesPerFrame = bakesPerFrame
        }
        if let maximumAnisotropy {
            settings.tiles.rasterization.maximumAnisotropy = maximumAnisotropy
        }
        if let mipLevelBias {
            settings.tiles.rasterization.mipLevelBias = mipLevelBias
        }
        return settings
    }

    /// The flattened ground on or off. Off, every tile keeps its layers.
    /// On, the zoom it starts from is the configured one.
    func groundFlattening(isEnabled: Bool) -> ImmersiveMapSettings {
        var settings = self
        if isEnabled {
            if settings.tiles.groundFlattening.fromTileZoom == nil {
                settings.tiles.groundFlattening.fromTileZoom = TileSettings.GroundFlatteningSettings().fromTileZoom
            }
        } else {
            settings.tiles.groundFlattening.fromTileZoom = nil
        }
        return settings
    }

    /// The deepest tile zoom level requested from the source. Past it the
    /// camera keeps zooming and the renderer scales the deepest tiles up.
    func tileMaximumZoomLevel(_ maximumZoomLevel: Int) -> ImmersiveMapSettings {
        var settings = self
        settings.tiles.coverage.maximumZoomLevel = maximumZoomLevel
        return settings
    }

    /// The byte quota of the prepared tile cache on disk: parsed and
    /// tessellated tiles, which is where every tile the camera has already
    /// looked at comes back from. See
    /// `ImmersiveMapView.preparedTileDiskCacheSize(bytes:)`.
    func preparedTileDiskCacheSize(bytes: Int) -> ImmersiveMapSettings {
        var settings = self
        settings.tiles.cache.preparedDiskCacheSizeInBytes = bytes
        return settings
    }

    /// Adjusts only the provided cache fields; nil leaves a field unchanged.
    /// `memoryCacheSizeInBytes` is accepted for source compatibility and
    /// ignored: tiles stay in GPU memory only while a frame draws them.
    func tileSettings(clearDiskCachesOnLaunch: Bool? = nil,
                      urlCacheEnabled: Bool? = nil,
                      preparedTileCacheEnabled: Bool? = nil,
                      preparedDiskCompressionEnabled: Bool? = nil,
                      preparedDiskTimeToLive: TimeInterval? = nil,
                      memoryCacheSizeInBytes: Int? = nil) -> ImmersiveMapSettings {
        tileSettings(clearDiskCachesOnLaunch: clearDiskCachesOnLaunch,
                     urlCacheEnabled: urlCacheEnabled,
                     preparedTileCacheEnabled: preparedTileCacheEnabled,
                     preparedDiskCompressionEnabled: preparedDiskCompressionEnabled,
                     preparedDiskTimeToLive: preparedDiskTimeToLive,
                     preparedDiskCacheSizeInBytes: nil,
                     memoryCacheSizeInBytes: memoryCacheSizeInBytes)
    }

    /// Adjusts only the provided cache fields; nil leaves a field unchanged.
    /// `memoryCacheSizeInBytes` is accepted for source compatibility and
    /// ignored: tiles stay in GPU memory only while a frame draws them.
    func tileSettings(clearDiskCachesOnLaunch: Bool? = nil,
                      urlCacheEnabled: Bool? = nil,
                      preparedTileCacheEnabled: Bool? = nil,
                      preparedDiskCompressionEnabled: Bool? = nil,
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
        if let preparedDiskCompressionEnabled {
            settings.tiles.cache.preparedDiskCompressionEnabled = preparedDiskCompressionEnabled
        }
        if let preparedDiskTimeToLive {
            settings.tiles.cache.preparedDiskTimeToLive = preparedDiskTimeToLive
        }
        if let preparedDiskCacheSizeInBytes {
            settings.tiles.cache.preparedDiskCacheSizeInBytes = preparedDiskCacheSizeInBytes
        }
        if let memoryCacheSizeInBytes {
            settings.tiles.cache.legacyMemoryCacheSizeInBytes = memoryCacheSizeInBytes
        }
        return settings
    }

    func offlineTileSettings(_ offline: TileSettings.OfflineSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.tiles.offline = offline
        return settings
    }

    /// How the tile loader uses regions downloaded through
    /// `ImmersiveMapOfflineController`: `.automatic` falls back to them when
    /// the network fails, `.offlineOnly` never touches the network at all.
    func offlineTileMode(_ mode: TileSettings.OfflineSettings.Mode) -> ImmersiveMapSettings {
        var settings = self
        settings.tiles.offline.mode = mode
        return settings
    }

    func labelSettings(_ labels: LabelSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.labels = labels
        return settings
    }

    /// Adjusts only the provided label fields; nil leaves a field unchanged.
    func labelSettings(language: LabelLanguage? = nil,
                       fallbackPolicy: LabelFallbackPolicy? = nil) -> ImmersiveMapSettings {
        var settings = self
        if let language {
            settings.labels.language = language
        }
        if let fallbackPolicy {
            settings.labels.fallbackPolicy = fallbackPolicy
        }
        return settings
    }

    /// Labels on or off: place names, points of interest, house numbers
    /// and road names. Applies live, the prepared tiles keep their text.
    func labels(isEnabled: Bool = true) -> ImmersiveMapSettings {
        var settings = self
        settings.labels.isEnabled = isEnabled
        return settings
    }

    func sceneSettings(_ scene: SceneSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.scene = scene
        return settings
    }

    /// Leaves the area outside the globe unpainted: no space background, no
    /// stars, and a frame that carries its own transparency.
    func transparentSpace(_ isTransparent: Bool = true) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.space.isTransparent = isTransparent
        return settings
    }

    func sceneLight(direction: SIMD3<Float>) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.light.direction = direction
        return settings
    }

    func shadowSettings(_ shadows: ShadowSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.shadows = shadows
        return settings
    }

    func atmosphereSettings(_ atmosphere: AtmosphereSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.atmosphere = atmosphere
        return settings
    }

    /// The globe's atmosphere: the halo around the planet and the glow on the
    /// surface toward the limb.
    func atmosphere(isEnabled: Bool = true) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.atmosphere.isEnabled = isEnabled
        return settings
    }

    func fogSettings(_ fog: FogSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.fog = fog
        return settings
    }

    /// The flat map's sky on or off. Off leaves the sky the clear colour
    /// and only a thin seam-hiding band at the horizon line.
    func fog(isEnabled: Bool = true) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.fog.isEnabled = isEnabled
        return settings
    }

    /// The flat map's band at the horizon line drawn in toward the line
    /// with the camera zoom (`FogSettings.horizonBandZoomFade`).
    func fog(horizonBandZoomFade: ImmersiveMapZoomFade) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.fog.horizonBandZoomFade = horizonBandZoomFade
        return settings
    }

    func groundFogSettings(_ groundFog: GroundFogSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.groundFog = groundFog
        return settings
    }

    /// The fog on the ground of the flat map (`GroundFogSettings`): on or
    /// off, and every value a nil leaves as configured.
    func groundFog(isEnabled: Bool = true,
                   densityPerKilometer: ImmersiveMapZoomCurve? = nil,
                   heightMeters: ImmersiveMapZoomCurve? = nil,
                   startDistanceMeters: ImmersiveMapZoomCurve? = nil,
                   startSoftnessMeters: ImmersiveMapZoomCurve? = nil,
                   color: SIMD3<Float>? = nil,
                   maximumOpacity: ImmersiveMapZoomCurve? = nil,
                   veilsBuildings: Bool? = nil) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.groundFog.isEnabled = isEnabled
        if let veilsBuildings {
            settings.scene.groundFog.veilsBuildings = veilsBuildings
        }
        if let densityPerKilometer {
            settings.scene.groundFog.densityPerKilometer = densityPerKilometer
        }
        if let heightMeters {
            settings.scene.groundFog.heightMeters = heightMeters
        }
        if let startDistanceMeters {
            settings.scene.groundFog.startDistanceMeters = startDistanceMeters
        }
        if let startSoftnessMeters {
            settings.scene.groundFog.startSoftnessMeters = startSoftnessMeters
        }
        if let color {
            settings.scene.groundFog.color = color
        }
        if let maximumOpacity {
            settings.scene.groundFog.maximumOpacity = maximumOpacity
        }
        return settings
    }

    /// The extruded buildings' zoom and the rise out of the ground
    /// (`ExtrusionSettings`), a nil leaving a value as configured.
    func extrusion(buildingsMinimumZoom: Double? = nil, riseSeconds: TimeInterval? = nil) -> ImmersiveMapSettings {
        var settings = self
        if let buildingsMinimumZoom {
            settings.scene.extrusion.buildingsMinimumZoom = buildingsMinimumZoom
        }
        if let riseSeconds {
            settings.scene.extrusion.riseSeconds = max(riseSeconds, 0)
        }
        return settings
    }

    /// The rise out of the ground on or off. Off, a layer stands up at
    /// once. On, it takes the configured time, or the default when the
    /// configured time is zero.
    func extrusion(risesFromTheGround: Bool) -> ImmersiveMapSettings {
        var settings = self
        if risesFromTheGround {
            if settings.scene.extrusion.riseSeconds <= 0 {
                settings.scene.extrusion.riseSeconds = ExtrusionSettings().riseSeconds
            }
        } else {
            settings.scene.extrusion.riseSeconds = 0
        }
        return settings
    }

    func shadows(isEnabled: Bool = true) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.shadows.isEnabled = isEnabled
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

    /// Restyles the attribution badge without replacing the whole settings
    /// value: `nil` leaves a field unchanged. Because of that, `textColor`
    /// cannot be reset to the default here; pass a full `AttributionSettings`
    /// to `attributionSettings(_:)` instead.
    func attributionSettings(isVisible: Bool? = nil,
                             size: AttributionSettings.Size? = nil,
                             position: AttributionSettings.Position? = nil,
                             margin: Double? = nil,
                             textColor: SIMD4<Float>? = nil,
                             isProvidedExternally: Bool? = nil) -> ImmersiveMapSettings {
        var attribution = self.attribution
        if let isVisible {
            attribution.isVisible = isVisible
        }
        if let size {
            attribution.size = size
        }
        if let position {
            attribution.position = position
        }
        if let margin {
            attribution.margin = margin
        }
        if let textColor {
            attribution.textColor = textColor
        }
        if let isProvidedExternally {
            attribution.isProvidedExternally = isProvidedExternally
        }
        return attributionSettings(attribution)
    }

    /// Declares that the app shows the data credit itself, so hiding the badge
    /// stops logging the attribution warning. The license obligation stays
    /// with the app.
    func attributionProvidedExternally(_ isProvidedExternally: Bool = true) -> ImmersiveMapSettings {
        var settings = self
        settings.attribution.isProvidedExternally = isProvidedExternally
        return settings
    }

    /// What the badge actually shows: the app override, or, when absent, the
    /// hosted service's credit, which is what the default source requires. An
    /// app that points the map at its own data owns the credit and states it
    /// with `attributionSettings`.
    var resolvedAttribution: ImmersiveMapAttribution {
        attribution.attributionOverride ?? ImmersiveMapTilesService.attribution
    }

    func postProcessingSettings(_ postProcessing: PostProcessingSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.postProcessing = postProcessing
        return settings
    }

    /// FXAA over the finished frame, applied as the last pass. Off by
    /// default; see `PostProcessingSettings.fxaaEnabled`.
    func fxaa(isEnabled: Bool = true) -> ImmersiveMapSettings {
        var settings = self
        settings.postProcessing.fxaaEnabled = isEnabled
        return settings
    }

    /// MSAA 4x on the world pass, or back to one sample per pixel; see
    /// `PostProcessingSettings.multisampleCount`.
    func msaa(isEnabled: Bool = true) -> ImmersiveMapSettings {
        var settings = self
        settings.postProcessing.multisampleCount = isEnabled ? 4 : 1
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
