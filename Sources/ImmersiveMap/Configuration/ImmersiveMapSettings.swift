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
        /// The seconds in which the animated zoom closes half of what is
        /// left of its way to the camera's zoom. The camera's zoom is the
        /// fact of a frame, and the tiles, the rings and the camera's pose
        /// read it as it is. What dresses the frame by the zoom (the
        /// styles' zoom fades, the labels' reach) reads the
        /// animated one instead, and the relief's collapse a zoom held through
        /// a drag and then followed the same way, so a zoom that jumps in
        /// one frame, as it does over a relief when the point the camera
        /// looks at drops off a ridge onto the plain below, dresses the
        /// frame over a few frames rather than at once. A camera set
        /// outright snaps it. Zero makes the two one. Raise it for a
        /// slower settle, lower it for a quicker one.
        public var animatedZoomHalfLife: Double
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
                    animatedZoomHalfLife: Double = 0.15,
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
            self.animatedZoomHalfLife = animatedZoomHalfLife
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
    /// What is drawn over the map for the person at it to work it by: the
    /// debug panel (`DebugSettings.enableDebugPanel`), the camera's
    /// on-screen controls and the control zones at the screen's edges
    /// (`CameraSettings.controlZones`).
    public struct ControlsSettings: Equatable, Sendable {
        /// Whether every control is hidden at once, for a clean frame: a
        /// screenshot, a recording, a look at the map alone. Each control
        /// keeps its configuration and the debug panel the values dragged
        /// in it, so showing them again brings them back as they were, and
        /// the renderer is not rebuilt either way. The hidden debug panel
        /// costs the frame nothing. The attribution stays: the map data's
        /// license requires it on screen (`AttributionSettings`). False by
        /// default.
        public var isHidden: Bool

        public init(isHidden: Bool = false) {
            self.isHidden = isHidden
        }
    }

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
        /// Where in the globe's unroll into the plane, as a fraction
        /// `0...1` of the transition window, the globe's air starts giving
        /// way to the plane's. Up to here the atmosphere rides the unrolling
        /// surface's edge as it does on the resting globe, over space and
        /// the stars. From here to `airHandoverEnd` the halo and the limb's
        /// glow fade out while the flat map's sky fades in over them, the
        /// halo's colour turns into the sky's colour at the horizon, space
        /// behind the stars brightens into the map's colour, and the world
        /// tile is laid under the far ground as the plane's horizon
        /// backdrop. 0.7 by default. Applies live.
        public var airHandoverStart: Float
        /// Where the handover is complete, as a fraction `0...1` of the
        /// transition window, at or past `airHandoverStart`. From here to
        /// the end of the window the sphere's path draws exactly the
        /// plane's air, so the switch of surfaces at the end changes
        /// nothing on screen. 0.9 by default, where the unroll's geometry
        /// is a finished plane. Applies live.
        public var airHandoverEnd: Float

        public init(automaticTransitionStartZoom: Double,
                    automaticTransitionSpan: Double,
                    globeRadiusScale: Double,
                    isGlobeEnabled: Bool = true,
                    airHandoverStart: Float = 0.7,
                    airHandoverEnd: Float = 0.9) {
            self.automaticTransitionStartZoom = automaticTransitionStartZoom
            self.automaticTransitionSpan = automaticTransitionSpan
            self.globeRadiusScale = globeRadiusScale
            self.isGlobeEnabled = isGlobeEnabled
            self.airHandoverStart = airHandoverStart
            self.airHandoverEnd = airHandoverEnd
        }

        /// How far the globe's air has given way to the plane's at a point
        /// of the transition, `0...1`: 0 up to `airHandoverStart`, a
        /// smoothstep to 1 at `airHandoverEnd`, 1 from there on. A window
        /// of no width is a step at its start.
        public func airHandover(atTransition transition: Float) -> Float {
            let start = min(max(airHandoverStart, 0), 1)
            let end = min(max(airHandoverEnd, start), 1)
            let t = min(max((transition - start) / max(end - start, 1e-6), 0), 1)
            return t * t * (3 - 2 * t)
        }
    }

    public struct TileSettings: Equatable, Sendable {
        public struct CoverageSettings: Equatable, Sendable {
            public var maximumZoomLevel: Int
            /// How far past the visible ground the flat map's texture bands
            /// (the ring rules with a `rasterSize`) ask for their tiles, as
            /// a share of the footprint's reach from the camera: 0.25 by
            /// default, a quarter of the way further out on every side, 0
            /// for the visible ground alone. A far band's tile has no
            /// resident stand-in when it comes into view (its ancestors are
            /// the world cover, which nothing goes down to), so a turn of
            /// the camera that brings one in shows a hole in the far ground
            /// for the frames its load takes. With the margin the tile is
            /// asked for before it is in view, and it is in by the time it
            /// is. The geometry bands take no margin: their stand-ins cover
            /// a loading tile, and their tiles cost far more.
            public var rasterBandMarginShare: Float

            public init(maximumZoomLevel: Int, rasterBandMarginShare: Float = 0.25) {
                self.maximumZoomLevel = maximumZoomLevel
                self.rasterBandMarginShare = rasterBandMarginShare
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
            /// How many tiles are parsed at once, at least one. A parse runs
            /// at utility priority on the efficiency cores and holds its
            /// slot until the tile is in the GPU's buffers and saved. More
            /// slots land a burst of tiles sooner and take the cores the
            /// frame and the rest of the app share with them, fewer keep a
            /// fast zoom from crowding the device. 4 by default.
            public var maximumConcurrentParses: Int

            public static let defaultMaximumConcurrentParses = 4

            public init(addTestBorders: Bool,
                        maximumConcurrentParses: Int = ParsingSettings.defaultMaximumConcurrentParses) {
                self.addTestBorders = addTestBorders
                self.maximumConcurrentParses = maximumConcurrentParses
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
            /// Whether the ground is flattened at all. Off, every tile keeps
            /// its layers at every zoom.
            public var isEnabled: Bool
            /// The tile zoom the ground is flattened from: a tile of this
            /// zoom or deeper is flattened whatever the camera's zoom, a
            /// coarser one keeps its layers. Nil, the default, is the
            /// tileset's deepest zoom (`CoverageSettings.maximumZoomLevel`,
            /// `tileMaximumZoomLevel(_:)`): only the tiles the camera blows
            /// up to many screens are flattened, whatever depth the archive
            /// is built to. With the ground relief on, the relief's zoom
            /// stands in for this one (`GroundReliefSettings.appearZoom`).
            public var fromTileZoom: Int?
            /// The grid a flattened tile's triangles keep to, cells a side:
            /// no triangle crosses a cell. More cells, more triangles.
            /// Clamped to `1...256`. With the ground relief on, the relief
            /// is as fine as the grid: a cell of a coarse tile covers far
            /// more ground than a cell of a deep one, so `gridByTileZoom`
            /// gives the coarse zooms more cells.
            public var grid: Int
            /// The grid of a tile zoom, over `grid` for the zooms it names.
            /// By default the zooms the relief is drawn at
            /// (`GroundReliefSettings.appearZoom`, `collapseZoom`) take a
            /// cell of about the same ground, 75 m at the Alps' latitude
            /// from zoom 12 on and the 256 ceiling above it: 256 at zooms
            /// 9 to 11 (9 for a relief that appears there), 128 at 12,
            /// 64 at 13 and 32 at 14. A tile of 256 cells is some 130
            /// thousand triangles, so the overrides cost memory and
            /// parsing where the relief is drawn, and nothing without the
            /// relief, whose zooms are not flattened at all
            /// (`fromTileZoom`). The globe's zooms, should the relief be
            /// set to flatten them (`GroundReliefSettings.appearZoom`),
            /// take the grid the sphere is split by otherwise
            /// (`GroundGeometrySubdivider`): 64 cells at zooms 0 and 1, 32
            /// at 2 and 3, so the limb and the chords of the fills' edges
            /// stay as round as they are. The relief's zooms take 128 cells
            /// at zooms 9 to 12 and 64 at 13, 33 thousand triangles a tile
            /// at most: a vertex per height of the zoom 10 map the ground
            /// rises by (`GroundReliefSettings.displacementMaximumZoom`)
            /// from zoom 12 on, every second height at 11, every fourth at
            /// 10, which the eye does not tell apart from the near ring's
            /// 53 m, the slopes' shading being per pixel and finer. A finer
            /// displacement wants these raised with it.
            public var gridByTileZoom: [Int: Int]

            public static let defaultGridByTileZoom: [Int: Int] = [0: 64, 1: 64, 2: 32, 3: 32,
                                                                   9: 128, 10: 128, 11: 128, 12: 128, 13: 64, 14: 32]

            public init(isEnabled: Bool = true,
                        fromTileZoom: Int? = nil,
                        grid: Int = 16,
                        gridByTileZoom: [Int: Int] = Self.defaultGridByTileZoom) {
                self.isEnabled = isEnabled
                self.fromTileZoom = fromTileZoom
                self.grid = grid
                self.gridByTileZoom = gridByTileZoom
            }

            /// The grid of a tile of `tileZoom`.
            public func grid(forTileZoom tileZoom: Int) -> Int {
                gridByTileZoom[tileZoom] ?? grid
            }
        }

        /// The flattened ground raised by a heightmap: each flattened tile
        /// (`GroundFlatteningSettings`) takes its heights from a terrain
        /// tile over it, of the zoom the relief's detail picks (`detail`),
        /// or, where the terrain source has none that deep, from the
        /// deepest one over it. The vertices of the ground rise, so the
        /// relief is as fine as the flattening's grid. A tile is
        /// shown with its terrain or not at all: until both are in, what
        /// stood on its ground stands on (`TilePlacementPlanner`).
        ///
        /// A first step of the terrain: only the ground's fills rise. The
        /// roads, the ground lines, the buildings, the models, the labels
        /// and the ground's shadows stay on the plane, so a hill covers the
        /// roads that cross it. Read at draw time, not baked into the
        /// prepared tiles. On by default, on Mapterhorn's open terrain
        /// (`tileURLTemplate`): `groundRelief(isEnabled: false)` lays the
        /// map flat and flattens the tiles from the flattening's own zoom
        /// again, not from the relief's (`appearZoom`).
        public struct GroundReliefSettings: Equatable, Sendable {
            /// Whether the flattened ground rises. True by default.
            public var isEnabled: Bool
            /// The terrain tiles: a URL with `{z}`, `{x}` and `{y}` in it,
            /// of square images (PNG or WebP, of any size) whose pixels hold
            /// heights in `encoding`. The default is Mapterhorn's open
            /// global terrain, 30 m everywhere to zoom 12 and lidar deeper
            /// where a country publishes it. Mapterhorn asks to be credited,
            /// and the badge credits it while the relief reads its tiles
            /// (`credit`).
            public var tileURLTemplate: String
            /// How a pixel of a terrain tile holds its height
            /// (`GroundReliefEncoding`): Terrarium by default, as
            /// Mapterhorn serves. Set it with `tileURLTemplate` to a source
            /// in another encoding.
            public var encoding: GroundReliefEncoding
            /// How much taller than the ground's real heights the relief is
            /// drawn: 1 is true scale, 2 doubles every height. Raise it to
            /// see a gentle relief.
            public var exaggeration: Float
            /// The camera zoom the relief rises out of the plane at: below
            /// it the map is flat, no terrain is read or loaded and the
            /// camera stands on the plane, and the rise is a short
            /// animation in time (`transitionSeconds`) once the zoom
            /// crosses it, not a scaling with the zoom. 10 by default. 0
            /// draws the relief from the plane's first frame. Read at the
            /// zoom a drag over the terrain began with, held through the
            /// drag, as `collapseZoom` is.
            ///
            /// It is also the tile zoom the ground is flattened from
            /// (`tileZoom(deepestTileZoom:)`): only a flattened tile rises
            /// as geometry, and the tiles drawn as geometry on the relief
            /// are the frame's own, of the relief's zooms. A coarser tile
            /// is on the relief only in a far ring, drawn from a texture on
            /// a raised grid (`RasterTileRenderSubsystem`), or for a moment
            /// as a stand-in, drawn the same way or, when it was on the
            /// screen as geometry the frame before, as it was until the
            /// slot's own tile lands (`TileWorkingSetSubsystem
            /// .drawingOnTheRelief`), so it is parsed in layers as off the
            /// relief, its fills, its roads and its memory spared the
            /// flattening.
            public var appearZoom: Double
            /// The camera zoom the relief collapses into the plane at: from
            /// this zoom on the map is flat, and the collapse is a short
            /// animation in time (`transitionSeconds`), not a scaling with
            /// the zoom, so a zoom crossing it drops the mountains at once
            /// and a zoom crossing back raises them again. The terrain
            /// sources are 30 m cells over most of the world, with the
            /// buildings and the forests in them, and close up those cells
            /// read as hills where there are none, so a street-level view
            /// stands on the plane the way the big map services draw it.
            /// 13.7 by default. A zoom past the deepest keeps the relief at
            /// every zoom. Once collapsed no terrain is read or loaded and
            /// the camera stands on the plane. Read at the camera's zoom as
            /// a drag over the terrain began with it, held through the
            /// drag, and followed over a few frames once it ends
            /// (`CameraSettings.animatedZoomHalfLife`): a drag slides the
            /// point the camera looks at up and down the slopes, the zoom
            /// with it, and a threshold read at the zoom of the moment
            /// would drop and raise the mountains with every slope. The
            /// relief is never scaled with the zoom, for the same reason.
            public var collapseZoom: Double
            /// How long the relief takes to rise out of the plane and to
            /// collapse back into it, in seconds, when the zoom crosses
            /// `appearZoom` or `collapseZoom`: 0.3 by default. 0 switches
            /// at once.
            public var transitionSeconds: TimeInterval
            /// The coarsest terrain zoom a tile falls back to when the
            /// source has no terrain tile at its own zoom. Mapterhorn
            /// covers the whole world to zoom 12.
            public var minimumSourceZoom: Int
            /// The zoom of the terrain tiles the camera flies over, 10 by
            /// default: one map at every zoom, the map the point the camera
            /// looks at lies on and its height over the ground is kept by.
            /// The ground is drawn by its rings' own terrain, which the
            /// ring rules pick (`FlatRingRule.terrainZoomDrop`, the debug
            /// panel's Tiles tab) and may be a finer map near the camera
            /// than this one, disagreeing with it by their grids'
            /// difference, metres on a ridge. One map for the camera,
            /// because a camera that read the map of the zoom it has
            /// answers in a loop where a ray grazes a ridge: one zoom's map
            /// says ridge, the arm shortens, the zoom crosses a level, the
            /// next map says plain, the zoom crosses back, and the camera
            /// shakes between the two. Raise it for a camera that hugs the
            /// drawn ground more closely at the street zooms, at the cost
            /// of more terrain tiles read under the camera.
            public var cameraTerrainZoom: Int
            /// The finest terrain zoom the ground's vertices rise by, 10 by
            /// default: a ring whose terrain is finer than this (`FlatRingRule
            /// .terrainZoomDrop`, zoom 13 at the near ring of a zoom 13
            /// frame) still shades its slopes by that terrain, pixel by
            /// pixel, but displaces its grid by this zoom's tile over it, one
            /// height every 53 m at zoom 10 on the Alps' latitude. The grid
            /// then needs a vertex per height of this map, 64 cells on a zoom
            /// 13 tile instead of 256, a sixteenth of the triangles, and the
            /// fine terrain is spent where the eye reads it, on the shading:
            /// the folds and ridges of a mountain are the light on its
            /// slopes, the silhouette only its outline. Raise it for sharper
            /// summits and silhouettes at the price of denser grids
            /// (`GroundFlatteningSettings.gridByTileZoom` has to follow), lower
            /// it for a lighter frame.
            public var displacementMaximumZoom: Int
            /// How many terrain tiles load at once, at least one. The frame
            /// asks for the terrain it needs nearest first
            /// (`GroundReliefStore.request(tiles:)`), and the loads take
            /// that order. More slots fill a fresh view sooner over a fast
            /// network, fewer leave the network and the decoding cores to
            /// the map's tiles. 4 by default.
            public var maximumConcurrentLoads: Int
            /// How many bytes of terrain tiles the frame has stopped reading
            /// are kept for a frame that reads them again, the most recently
            /// released kept: a zoom out below the relief's zoom and back,
            /// or a pan away and back, finds its terrain without a load or
            /// a decode. The frame's own terrain is never counted against
            /// it, it is kept for as long as the frame reads it. 50 MB by
            /// default, about fifty tiles. 0 keeps nothing: every terrain
            /// the frame stops reading is loaded again when it is read
            /// again. Lower it on a device short of memory.
            public var releasedCacheBytes: Int
            /// The height in metres the camera keeps over a ridge under it,
            /// the terrain between the eye and the point it looks at that
            /// rises over that point. Zero by default: the camera flies
            /// right up to the ridge and is held only from going under
            /// its surface. Set, the margin grows with the ridge's rise,
            /// from nothing over ground level with the point to this over
            /// a ridge this much higher, so over level ground nothing ever
            /// holds the camera off the point it looks at: the zoom goes
            /// to its own limit. Set it if the near ground cuts into the
            /// view on a slope.
            public var cameraClearanceMetres: Float
            /// Whether the mountains cast their shadows: the relief drawn
            /// into the shadow map (`ShadowSettings`) as the buildings are,
            /// so a ridge darkens the valley behind it from the scene's sun
            /// (`SceneLightSettings.direction`), and the ground, its
            /// buildings and its labels' ground take the shadow. Within the
            /// shadow map's windows only (`ShadowSettings.coverageCameraDistances`,
            /// `farCoverageCameraDistances`), fading at their rim, only with
            /// the shadows on and from the shadows' zoom
            /// (`ShadowSettings.minimumZoom`, 14 by default, past the zoom the
            /// relief collapses at, so the mountains cast only where that zoom
            /// is set lower, and the hillshade carries them otherwise). The slopes' own
            /// shading is the hillshade's (`ImmersiveMapHillshade`).
            /// True by default. The shadow map is drawn again when the
            /// terrain under it changes, so a camera at rest costs nothing.
            public var castsShadows: Bool
            /// How the country around the point the camera looks at is read
            /// as mountains or a plain (`TerrainSurroundingsSettings`), the
            /// reading `ImmersiveMapView.onTerrainSurroundingsChange` reports.
            public var surroundings: TerrainSurroundingsSettings

            public init(isEnabled: Bool = true,
                        tileURLTemplate: String = "https://tiles.mapterhorn.com/{z}/{x}/{y}.webp",
                        encoding: GroundReliefEncoding = .terrarium,
                        exaggeration: Float = 1,
                        appearZoom: Double = 10,
                        collapseZoom: Double = 13.7,
                        transitionSeconds: TimeInterval = 0.3,
                        minimumSourceZoom: Int = 12,
                        cameraTerrainZoom: Int = 10,
                        displacementMaximumZoom: Int = 10,
                        maximumConcurrentLoads: Int = 4,
                        releasedCacheBytes: Int = 50 << 20,
                        cameraClearanceMetres: Float = 0,
                        castsShadows: Bool = true,
                        surroundings: TerrainSurroundingsSettings = TerrainSurroundingsSettings()) {
                self.isEnabled = isEnabled
                self.tileURLTemplate = tileURLTemplate
                self.encoding = encoding
                self.exaggeration = exaggeration
                self.appearZoom = appearZoom
                self.collapseZoom = collapseZoom
                self.transitionSeconds = transitionSeconds
                self.minimumSourceZoom = minimumSourceZoom
                self.cameraTerrainZoom = cameraTerrainZoom
                self.displacementMaximumZoom = displacementMaximumZoom
                self.maximumConcurrentLoads = maximumConcurrentLoads
                self.releasedCacheBytes = releasedCacheBytes
                self.cameraClearanceMetres = cameraClearanceMetres
                self.castsShadows = castsShadows
                self.surroundings = surroundings
            }

            /// The tile zoom of `appearZoom`: the zoom of the frame's tiles
            /// when the relief rises, the tiles drawn as geometry on it, and
            /// the zoom the ground is flattened from and a frame is on the
            /// terrain from. A tileset stopping short of it is flattened
            /// from its deepest zoom (`deepestTileZoom`), which stands in
            /// for every zoom past it.
            func tileZoom(deepestTileZoom: Int) -> Int {
                let zoom = appearZoom.isFinite ? Int(max(appearZoom, 0).rounded(.down)) : 0
                return max(0, min(zoom, deepestTileZoom))
            }

            /// The credit Mapterhorn's terrain asks for, laid on the
            /// attribution line after the overview's while the relief is on
            /// and reads Mapterhorn's tiles (`ImmersiveMapSettings
            /// .resolvedAttribution`), at the camera zooms the relief stands
            /// out of the plane at, from `appearZoom` up to `collapseZoom`:
            /// below and past them no terrain is read and the map draws none
            /// of it. Nil when the relief is off, never rises, or reads
            /// another source, whose credit the app states with
            /// `attributionSettings`.
            var credit: ImmersiveMapAttribution.Credit? {
                guard isEnabled,
                      tileURLTemplate.hasPrefix(Self.mapterhornTileURLPrefix),
                      appearZoom < collapseZoom else {
                    return nil
                }
                return ImmersiveMapAttribution.Credit(Self.mapterhornCreditText,
                                                      zoomRange: appearZoom..<collapseZoom)
            }

            static let mapterhornTileURLPrefix = "https://tiles.mapterhorn.com/"
            static let mapterhornCreditText = "© Mapterhorn"
        }

        /// How the country around the point the camera looks at is read as
        /// mountains or a plain (`GroundReliefSettings.surroundings`,
        /// `ImmersiveMapTerrainSurroundings`): the relief's heights are
        /// read on the CPU over a disc around the point, and the span of
        /// them, the highest less the lowest, says how mountainous the
        /// country is. Read only while the frame is on the terrain. Tune it
        /// on the debug panel's Relief tab, which shows the reading live.
        public struct TerrainSurroundingsSettings: Equatable, Sendable {
            /// The radius of the disc the heights are read over, in metres,
            /// 4000 by default. Wider reads the region, so a town at the foot
            /// of a range counts as mountains sooner, narrower reads the
            /// ground at hand, so a wide valley floor counts as a plain.
            public var sampleRadiusMetres: Float
            /// The span of heights under which the country is a plain, in
            /// metres, 150 by default: the mountainousness is 0 there, and
            /// the kind falls back to `.plain` once the span is under it.
            public var plainBelowMetres: Float
            /// The span of heights from which the country is mountains, in
            /// metres, 600 by default: the mountainousness is 1 there, and
            /// the kind rises to `.mountains` once the span reaches it. The
            /// band between the two thresholds is the kind's hysteresis.
            public var mountainsAboveMetres: Float
            /// How long the span takes to go half the way to a new reading,
            /// in seconds, 0.5 by default: a pan into the mountains fades
            /// the reading in rather than steps it. 0 follows at once.
            public var smoothingHalfLife: TimeInterval

            public init(sampleRadiusMetres: Float = 4000,
                        plainBelowMetres: Float = 150,
                        mountainsAboveMetres: Float = 600,
                        smoothingHalfLife: TimeInterval = 0.5) {
                self.sampleRadiusMetres = max(sampleRadiusMetres, 1)
                self.plainBelowMetres = max(plainBelowMetres, 0)
                self.mountainsAboveMetres = max(mountainsAboveMetres, 0)
                self.smoothingHalfLife = max(smoothingHalfLife, 0)
            }
        }

        /// How a pixel of a terrain tile holds its height in metres
        /// (`GroundReliefSettings.encoding`). Both are RGB images, PNG or
        /// WebP, and differ only in the arithmetic.
        public enum GroundReliefEncoding: String, CaseIterable, Equatable, Sendable {
            /// Red × 256 + green + blue / 256 − 32768: Mapterhorn, AWS
            /// Terrain Tiles and most open sources.
            case terrarium
            /// (Red × 65536 + green × 256 + blue) × 0.1 − 10000: Mapbox
            /// Terrain-DEM and Terrain-RGB, and MapTiler's terrain.
            case mapbox
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
        /// size draws its tiles' ground through a texture of their fills,
        /// drawn from the tile each frame and shown with its mipmaps
        /// (`RasterTileRenderSubsystem`), so the far ground is as smooth
        /// as a texture and as current as the geometry. These are how the
        /// textures are sampled. The size is the rule's, and every tile
        /// of a raster ring is drawn into its texture every frame, so a
        /// rule's size is a cost of the frame: 256 texels is plenty for
        /// a far ring.
        public struct RasterizationSettings: Equatable, Sendable {
            /// The anisotropic filtering of the textures, 1 to 16 samples.
            /// The far rings are seen almost edge on, where a texture
            /// without it blurs along the view. Lower it only on a GPU short
            /// of bandwidth.
            public var maximumAnisotropy: Int
            /// Added to the mip level the GPU picks: above 0 the far ground
            /// is softer and quieter, below 0 sharper and busier.
            public var mipLevelBias: Float

            public init(maximumAnisotropy: Int = 16,
                        mipLevelBias: Float = 0) {
                self.maximumAnisotropy = maximumAnisotropy
                self.mipLevelBias = mipLevelBias
            }
        }

        /// The overview of the globe the engine ships (`OverviewTileSource`):
        /// hand-drawn biomes laid into the tiles of zooms 0 to 7 under the
        /// tile source's raster-derived land cover, which the built-in
        /// style paints and draws the land cover over
        /// (`ProtomapsBasemapTheme.BiomeStyles`, where the zooms are set).
        public struct OverviewSettings: Equatable, Sendable {
            /// Whether the overview's layers are laid into the tiles. On by
            /// default. Off, the overview zooms draw the tile source's own
            /// land cover alone: for a source in another schema whose style
            /// has no use for the layers, or to see the source's land cover
            /// on the globe. Part of the prepared tiles' identity, so a
            /// change re-parses them.
            public var isEnabled: Bool

            /// The camera zoom the overview's credit (the biomes' license
            /// asks for one, `OverviewTileSource.credit`) stays on the
            /// attribution line up to: from there on the map draws none of
            /// the overview and the credit goes. 8 by default, where the
            /// built-in style has faded the biomes out (the fade from tile
            /// zoom `ProtomapsBasemapTheme.BiomeStyles.maximumTileZoom` to
            /// the next). Raise or lower it with a theme that keeps the
            /// biomes to another zoom. A change applies live, without a
            /// re-parse.
            public var creditMaximumZoom: Double

            public init(isEnabled: Bool = true,
                        creditMaximumZoom: Double = 8) {
                self.isEnabled = isEnabled
                self.creditMaximumZoom = creditMaximumZoom
            }
        }

        public var coverage: CoverageSettings
        public var network: NetworkSettings
        public var cache: CacheSettings
        public var parsing: ParsingSettings
        public var groundFlattening: GroundFlatteningSettings
        public var groundRelief: GroundReliefSettings
        public var offline: OfflineSettings
        public var rasterization: RasterizationSettings
        public var overview: OverviewSettings

        public init(coverage: CoverageSettings,
                    network: NetworkSettings,
                    cache: CacheSettings,
                    parsing: ParsingSettings,
                    offline: OfflineSettings = OfflineSettings(),
                    groundFlattening: GroundFlatteningSettings = GroundFlatteningSettings(),
                    groundRelief: GroundReliefSettings = GroundReliefSettings(),
                    rasterization: RasterizationSettings = RasterizationSettings(),
                    overview: OverviewSettings = OverviewSettings()) {
            self.coverage = coverage
            self.network = network
            self.cache = cache
            self.parsing = parsing
            self.offline = offline
            self.groundFlattening = groundFlattening
            self.groundRelief = groundRelief
            self.rasterization = rasterization
            self.overview = overview
        }

        /// The tile zoom the ground is flattened from, with the relief in:
        /// the relief's (`GroundReliefSettings.appearZoom`), the zoom of the
        /// frame's own tiles when the relief rises, the tiles drawn as
        /// geometry on it. Else the flattening's own, the tileset's deepest
        /// zoom when it names none, and nil when the flattening is off.
        /// Every reader of the flattening's zoom reads this.
        var resolvedGroundFlatteningFromTileZoom: Int? {
            if groundRelief.isEnabled {
                return groundRelief.tileZoom(deepestTileZoom: coverage.maximumZoomLevel)
            }
            guard groundFlattening.isEnabled else { return nil }
            return groundFlattening.fromTileZoom ?? coverage.maximumZoomLevel
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
        /// How dark the shadows are, 0 to 1, by the camera zoom: nothing
        /// up to zoom 14, the buildings' zoom
        /// (`ExtrusionSettings.buildingsMinimumZoom`), and 0.22 from zoom
        /// 15 on by default, rising smoothly between the two stops so the
        /// shadows never appear at one frame. Where the curve is zero no shadow pass
        /// runs. From an overview the shadows of the mountains and the
        /// buildings read as stains on the map, and the hillshade carries
        /// the relief on its own. Put the first stop lower for a map that
        /// wants the mountains' shadows from afar (the relief draws from
        /// `GroundReliefSettings.appearZoom`, 10 by default), higher for
        /// shadows in street views alone. Read at the animated zoom, so a
        /// zoom gesture plays the change.
        public var strength: ImmersiveMapZoomCurve
        /// Square shadow map side in pixels. Clamped to `256...4096` at render time.
        public var mapResolution: Int
        /// Coverage radius of the shadow map's near window, in metres on
        /// the ground around the point the camera looks at, by the camera
        /// zoom: 24 km at zoom 12, 6 km at 14, 1.5 km at 16 and 500 m at
        /// 18 by default, halving with every zoom between the stops as the
        /// map's scale does (the curve runs geometrically). One slice of
        /// the map is stretched over the radius, so raising it coarsens
        /// every shadow in the window in proportion, and `mapResolution` is
        /// what buys the density back. The window is fitted to the visible
        /// ground inside the radius, so metres the camera cannot see cost
        /// nothing. Clamped to `5...1_000_000` m. Over the outer quarter of
        /// the radius the near window hands over to the far one
        /// (`farCoverageMeters`), or the shadows fade out without it, so
        /// the window's edge is never visible as a circle at any coverage.
        /// A few metres are a debugging aid: they wind the window down onto
        /// the point the camera looks at, which is how the shadow map's
        /// texel grid is looked at up close. In metres rather than camera
        /// distances, like the ground fog's lengths, so the same curve
        /// means the same ground on every screen and at every pitch.
        public var nearCoverageMeters: ImmersiveMapZoomCurve
        /// Coverage radius of the shadow map's far window, in the same
        /// metres by the zoom: the second slice of the map, as many texels
        /// over a wider disc and so coarser, for the shadows beyond the
        /// near window, the mountains casting across a valley from
        /// kilometres away. Four times the near coverage by default (96 km
        /// at zoom 12 down to 1.5 km at 18). A receiver reads the near
        /// window where it reaches and the far one past it, and the shadows
        /// fade out over the outer quarter of this radius. The far window
        /// is fitted only when its fade band starts where the near window
        /// ends or beyond, at four thirds of the near coverage or more:
        /// under that the setting is off at that zoom, the frame has the
        /// near window alone and pays for one. Raise it to shadow farther
        /// ground, lower it for sharper far shadows, and set it under the
        /// near coverage for the one window of a city map without a relief.
        public var farCoverageMeters: ImmersiveMapZoomCurve
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
                    strength: ImmersiveMapZoomCurve = [14: 0, 15: 0.22],
                    mapResolution: Int = 4096,
                    nearCoverageMeters: ImmersiveMapZoomCurve = [12: 24_000, 14: 6000, 16: 1500, 18: 500],
                    farCoverageMeters: ImmersiveMapZoomCurve = [12: 96_000, 14: 24_000, 16: 6000, 18: 1500],
                    maxCasterHeightMeters: Float = 500,
                    normalOffsetTexels: Float = 2.5,
                    softness: Float = 1.5,
                    tint: SIMD3<Float> = SIMD3<Float>(0.88, 0.92, 1.0)) {
            self.isEnabled = isEnabled
            self.strength = strength
            self.mapResolution = mapResolution
            self.nearCoverageMeters = nearCoverageMeters
            self.farCoverageMeters = farCoverageMeters
            self.maxCasterHeightMeters = maxCasterHeightMeters
            self.normalOffsetTexels = normalOffsetTexels
            self.softness = softness
            self.tint = tint
        }

        /// The strength at a camera zoom, 0 to 1.
        func strength(atZoom zoom: Double) -> Float {
            min(max(strength.value(atZoom: zoom), 0), 1)
        }

        /// The near window's coverage at a camera zoom, in metres: the
        /// curve runs geometrically, as a length on the ground does.
        func nearCoverageMeters(atZoom zoom: Double) -> Float {
            nearCoverageMeters.value(atZoom: zoom, interpolation: .geometric)
        }

        /// The far window's coverage at a camera zoom, in metres.
        func farCoverageMeters(atZoom zoom: Double) -> Float {
            farCoverageMeters.value(atZoom: zoom, interpolation: .geometric)
        }
    }

    /// The globe's atmosphere: a halo of scattered light around the
    /// planet's limb and a matching glow on the surface toward it. The
    /// globe's, on the resting sphere and along the edge of the unrolling
    /// surface alike. Over the last stretch of the globe-to-flat morph
    /// (`PresentationSettings.airHandoverStart` to `airHandoverEnd`) it
    /// hands over to the flat map's sky (`FogSettings`), and the flat map
    /// has no atmosphere.
    /// A thin glow at the limb that hides the tile mesh's edge stays even
    /// with the atmosphere off.
    public struct AtmosphereSettings: Equatable, Sendable {
        public var isEnabled: Bool
        /// The color of the scattered light, RGB in `0...1`. A deep blue by
        /// default; the very edge of the halo whitens toward the limb on
        /// its own.
        public var color: SIMD3<Float>
        /// Brightness multiplier of the halo and of the surface glow. Expected
        /// range: `0...2`; 1 is the designed look, 0 leaves the sphere bare
        /// while keeping the layer on.
        public var intensity: Float
        /// Width multiplier of the halo, relative to the globe radius, by
        /// the camera zoom (`ImmersiveMapZoomCurve`): 1 is the full shell,
        /// 0.25 a thin bright ring hugging the limb, 3 three times the full
        /// shell. The halo scales with the globe on screen, so at one zoom
        /// it looks the same from every side, and the curve lets it be a
        /// wide glow around the whole planet from afar and a thin ring as
        /// the camera comes down to the surface. By default 3 up to zoom 2,
        /// down to 0.25 by zoom 6, where the globe unrolls. A single value
        /// states the same at every zoom.
        public var thickness: ImmersiveMapZoomCurve
        /// How much the scene light (`SceneLightSettings.direction`, the sun
        /// the buildings cast their shadows from) shapes the halo, `0...1`:
        /// at 1 the halo is full where the limb faces the light and dims to
        /// a residual glow opposite it; at 0 it is the same brightness all
        /// the way around.
        public var sunInfluence: Float

        public init(isEnabled: Bool = true,
                    color: SIMD3<Float> = SIMD3<Float>(0.008, 0.18, 0.482),
                    intensity: Float = 1.2,
                    thickness: ImmersiveMapZoomCurve = [2: 3, 6: 0.25],
                    sunInfluence: Float = 0.69) {
            self.isEnabled = isEnabled
            self.color = color
            self.intensity = intensity
            self.thickness = thickness
            self.sunInfluence = sunInfluence
        }
    }

    /// The sky of the flat presentation: above the horizon line the sky, a
    /// short pale glow at the line that gives way to the sky colour within
    /// a few degrees. On by default. Off, nothing is painted above the
    /// line (the sky is the map's clear colour). Nothing is painted on the
    /// ground under the line: the far ground is veiled by the ground fog
    /// (`GroundFogSettings`), by its distance,
    /// which takes its colour from `horizonColor`. The globe has its own
    /// treatment, `AtmosphereSettings`. Over the last stretch of the
    /// globe-to-flat morph (`PresentationSettings.airHandoverStart` to
    /// `airHandoverEnd`) the atmosphere hands over to this.
    public struct FogSettings: Equatable, Sendable {
        public var isEnabled: Bool
        /// The sky's colour away from the horizon, RGB in `0...1`.
        public var skyColor: SIMD3<Float>
        /// The colour at the horizon: the glow the sky brightens into over
        /// its last degrees coming down and, unless it states its own, the
        /// ground fog, so the two meet at the line in one colour. White by
        /// default, the way a hazy day's sky whitens toward the ground.
        public var horizonColor: SIMD3<Float>

        public init(isEnabled: Bool = true,
                    skyColor: SIMD3<Float> = SIMD3<Float>(0.40, 0.66, 1.0),
                    horizonColor: SIMD3<Float> = SIMD3<Float>(0.97, 0.97, 0.98)) {
            self.isEnabled = isEnabled
            self.skyColor = skyColor
            self.horizonColor = horizonColor
        }

        /// The air of a night, for the night palette
        /// (`ProtomapsBasemapTheme.night`): the sky a deep navy, the
        /// horizon a shade lighter in the hue of the palette's water, so
        /// the far city sinks into the night and the ground fog, which
        /// takes the horizon's colour unless it states its own, meets the
        /// sky at the line.
        public static let night = FogSettings(skyColor: SIMD3<Float>(0.03, 0.05, 0.11),
                                              horizonColor: SIMD3<Float>(0.09, 0.12, 0.22))
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

        public init(buildingsMinimumZoom: Double = 14,
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
    /// tall building rises out of it. It veils the ground, the roads, the
    /// labels painted on the map, the buildings and the models
    /// (`veilsBuildings`), so it hides the far detail and its shimmer and
    /// draws the eye to the near ground. On by default. The horizon's sky
    /// (`FogSettings`) is the horizon's own: either can be on without the
    /// other. The globe has none.
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
    ///
    /// On the ground relief the fog is the air over the mountains: its
    /// height is measured from sea level (`heightsFromSeaLevel`), so a
    /// valley lies deeper in it than the summit over it, and the far
    /// ridges stand out of the hazed valleys behind them, each lighter
    /// than the one before. `baseAltitudeMeters` is the altitude the
    /// density is stated at. The debug panel's Air tab drags all of it.
    public struct GroundFogSettings: Equatable, Sendable {
        /// The air over mountains to start from, made of a plain's air
        /// (`SceneSettings.mountainGroundFog`, its default over the default
        /// plain air): the haze from the camera on with no clear stretch,
        /// thin (half the light gone in some 35 km), a 2.5 km layer that is
        /// thickest up to the valleys' floor at 1500 m and thins over the
        /// summits, in the plain air's own colour (the horizon's white by
        /// default). The stops at zooms 7 and 12 are replaced, the street
        /// zooms' (16 and 22) kept, so the city's fog stays as the app has
        /// it.
        public static func mountainAir(from plain: GroundFogSettings) -> GroundFogSettings {
            var preset = plain
            preset.isEnabled = true
            preset.heightsFromSeaLevel = true
            preset.baseAltitudeMeters = 1500
            preset.densityPerKilometer = replacingOverviewStops(of: plain.densityPerKilometer, with: 0.02)
            preset.heightMeters = replacingOverviewStops(of: plain.heightMeters, with: 2500)
            // Geometric curves cannot hold a zero: ten metres is no clear
            // stretch to speak of.
            preset.startDistanceMeters = replacingOverviewStops(of: plain.startDistanceMeters, with: 10)
            preset.startSoftnessMeters = replacingOverviewStops(of: plain.startSoftnessMeters, with: 3000)
            return preset
        }

        /// The zooms the overview's stops of the shipping curves sit at,
        /// the relief's zooms and below.
        static let overviewStopZooms: ClosedRange<Double> = 0...13

        /// `curve` with every stop up to zoom 13 dropped and one value put
        /// at zooms 7 and 12 in their place: the overview reads it, and the
        /// stops past it are the curve's own.
        static func replacingOverviewStops(of curve: ImmersiveMapZoomCurve, with value: Float) -> ImmersiveMapZoomCurve {
            let kept = curve.stops.filter { overviewStopZooms.contains($0.zoom) == false }
            return ImmersiveMapZoomCurve(stops: kept + [ImmersiveMapZoomCurve.Stop(zoom: 7, value: value),
                                                        ImmersiveMapZoomCurve.Stop(zoom: 12, value: value)])
        }

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
        /// The fog's colour, RGB in `0...1`. Nil takes the horizon's colour
        /// (`FogSettings.horizonColor`), so the fog meets the sky at the
        /// line in one colour.
        public var color: SIMD3<Float>?
        /// The most the fog veils anything, `0...1`: under 1 the farthest
        /// ground still shows through, and at 0 there is no fog. The value
        /// to bring the fog in or out with the zoom.
        public var maximumOpacity: ImmersiveMapZoomCurve
        /// Whether the fog veils the extruded buildings and the models with
        /// the ground. On (the default) a far building sinks into the fog
        /// from its base up, standing in it as the ground does. Off they
        /// draw in their own colour, crisp, and seem to float over the
        /// fogged ground at their feet.
        public var veilsBuildings: Bool
        /// Whether the fog takes the sky's colour above the horizon line,
        /// in the direction of the view, where the horizon paints a sky
        /// (`FogSettings.isEnabled`). Off (the default) the fog is one
        /// colour everywhere, and a far building fades toward it as into a
        /// haze. On, a building veiled in full is the sky behind it, which
        /// reads as the building turning see-through.
        public var takesSkyColor: Bool
        /// On the ground relief, whether the fog's height is measured from
        /// sea level, the terrain's own metres (on, the default), or from
        /// the plane the ground is drawn from, the terrain under the point
        /// the camera looks at. From sea level, the density falls with the
        /// altitude of the ground itself: the floor of a valley at 1500 m
        /// is in denser air than a ridge at 3000 m whatever the camera
        /// looks at, which is what layers the ridges. From the plane, the
        /// ground under the camera's point is always at the full density,
        /// and the fog follows the camera up and down the slopes. Off the
        /// relief the two are one and the same.
        public var heightsFromSeaLevel: Bool
        /// The altitude the density is stated at, in meters: at and below
        /// it the fog is `densityPerKilometer` thick, above it the density
        /// falls by a factor of e every `heightMeters`. 0 by default, sea
        /// level. Raise it to the valleys' floor for mountains whose air is
        /// meant to be thick in the valleys and thin on the summits, at a
        /// smaller `heightMeters`. Read only with `heightsFromSeaLevel`.
        public var baseAltitudeMeters: Float

        public init(isEnabled: Bool = true,
                    densityPerKilometer: ImmersiveMapZoomCurve = [7: 0.0019, 12: 0.06, 16: 17, 22: 6],
                    heightMeters: ImmersiveMapZoomCurve = [7: 256_000, 12: 8000, 16: 150, 22: 60],
                    startDistanceMeters: ImmersiveMapZoomCurve = [7: 1_280_000, 12: 40_000, 16: 400, 22: 250],
                    startSoftnessMeters: ImmersiveMapZoomCurve = [7: 4_800_000, 12: 150_000, 16: 800, 22: 950],
                    color: SIMD3<Float>? = nil,
                    maximumOpacity: ImmersiveMapZoomCurve = [8: 0, 10: 1],
                    veilsBuildings: Bool = true,
                    takesSkyColor: Bool = false,
                    heightsFromSeaLevel: Bool = true,
                    baseAltitudeMeters: Float = 0) {
            self.isEnabled = isEnabled
            self.densityPerKilometer = densityPerKilometer
            self.heightMeters = heightMeters
            self.startDistanceMeters = startDistanceMeters
            self.startSoftnessMeters = startSoftnessMeters
            self.color = color
            self.maximumOpacity = maximumOpacity
            self.veilsBuildings = veilsBuildings
            self.takesSkyColor = takesSkyColor
            self.heightsFromSeaLevel = heightsFromSeaLevel
            self.baseAltitudeMeters = baseAltitudeMeters
        }
    }

    /// The sun on the globe: the planet's surface shaded by the sphere's
    /// normal against a sun fixed to the Earth, over the subsolar point
    /// (`subsolarLatitudeDegrees`, `subsolarLongitudeDegrees`), the day
    /// side as the style paints it and the night side drawn toward a night
    /// colour, with a soft terminator between. The terminator lies on one
    /// part of the planet whichever way the globe is turned, and the
    /// atmosphere's halo brightens toward the same sun. Without it the
    /// sphere is lit the same all over and reads flat. Globe presentation
    /// only: through the morph into the plane the shading fades out with
    /// the atmosphere, and the flat map has its own static sun
    /// (`SceneLightSettings.direction`), the hillshade and the shadows.
    public struct GlobeLightSettings: Equatable, Sendable {
        public var isEnabled: Bool
        /// Where the sun stands overhead, in degrees: the latitude north
        /// positive, the longitude east positive. Over the Atlantic off
        /// West Africa by default (10, -15), which lights Europe and Africa
        /// from the south-west and puts the night over Asia and the
        /// Pacific. The sun stays there as the globe turns.
        public var subsolarLatitudeDegrees: Float
        public var subsolarLongitudeDegrees: Float
        /// How far the night side goes toward `nightColor`, 0 to 1, by the
        /// camera zoom (`ImmersiveMapZoomCurve`): 1 draws the night side in
        /// the night colour outright, 0 leaves the surface as it is. By
        /// default 0.6 up to zoom 4, down to 0.3 by zoom 6, where the
        /// camera is close to the surface and the shading would only
        /// darken the map in view. A single value states the same at every
        /// zoom.
        public var strength: ImmersiveMapZoomCurve
        /// The width of the terminator, as the cosine of the sun's angle to
        /// the surface: the shading runs from day to night over
        /// `-terminatorSoftness...terminatorSoftness` of it. 0.25 by
        /// default, the halo's own dusk. Smaller is a sharper line, 1 a
        /// dusk over the whole lit half.
        public var terminatorSoftness: Float
        /// The colour the night side is drawn toward, RGB in `0...1`: a
        /// deep blue by default, the planet's night under a blue sky.
        public var nightColor: SIMD3<Float>

        public init(isEnabled: Bool = true,
                    subsolarLatitudeDegrees: Float = 10,
                    subsolarLongitudeDegrees: Float = -15,
                    strength: ImmersiveMapZoomCurve = [4: 0.6, 6: 0.3],
                    terminatorSoftness: Float = 0.25,
                    nightColor: SIMD3<Float> = SIMD3<Float>(0.05, 0.08, 0.18)) {
            self.isEnabled = isEnabled
            self.subsolarLatitudeDegrees = subsolarLatitudeDegrees
            self.subsolarLongitudeDegrees = subsolarLongitudeDegrees
            self.strength = strength
            self.terminatorSoftness = terminatorSoftness
            self.nightColor = nightColor
        }
    }

    public struct SceneSettings: Equatable, Sendable {
        public var space: SpaceSettings
        public var starfield: StarfieldSettings
        public var light: SceneLightSettings
        public var shadows: ShadowSettings
        public var atmosphere: AtmosphereSettings
        public var globeLight: GlobeLightSettings
        public var fog: FogSettings
        /// The air over the flat map, and over a plain where
        /// `mountainGroundFog` is set.
        public var groundFog: GroundFogSettings
        /// The air over the mountains: by default the mountain air made of
        /// the default plain air (`GroundFogSettings.mountainAir(from:)`),
        /// nil for one air everywhere. Set, the frame draws the air
        /// between this and `groundFog` by how
        /// mountainous the country around the camera reads
        /// (`ImmersiveMapTerrainSurroundings.mountainousness`, tuned with
        /// `TerrainSurroundingsSettings`): every value of the two airs is
        /// read at the zoom and mixed, so a pan from a plain into a range
        /// fades one air into the other. Read only with the relief on and
        /// the frame on the terrain, where the country can be read: off it
        /// the air is `groundFog`.
        public var mountainGroundFog: GroundFogSettings?
        public var extrusion: ExtrusionSettings

        public init(space: SpaceSettings,
                    starfield: StarfieldSettings,
                    light: SceneLightSettings = SceneLightSettings(),
                    shadows: ShadowSettings = ShadowSettings(),
                    atmosphere: AtmosphereSettings = AtmosphereSettings(),
                    globeLight: GlobeLightSettings = GlobeLightSettings(),
                    fog: FogSettings = FogSettings(),
                    groundFog: GroundFogSettings = GroundFogSettings(),
                    mountainGroundFog: GroundFogSettings? = GroundFogSettings.mountainAir(from: GroundFogSettings()),
                    extrusion: ExtrusionSettings = ExtrusionSettings()) {
            self.space = space
            self.starfield = starfield
            self.light = light
            self.shadows = shadows
            self.atmosphere = atmosphere
            self.globeLight = globeLight
            self.fog = fog
            self.groundFog = groundFog
            self.mountainGroundFog = mountainGroundFog
            self.extrusion = extrusion
        }
    }

    public struct DebugSettings: Equatable, Sendable {
        public var enableDebugPanel: Bool
        /// Whether the debug panel shows the zoom badge in the map's top
        /// trailing corner: the camera's zoom and the planning zoom, large,
        /// to read at a glance while a gesture is under way. On by default,
        /// shown only with the panel.
        public var showsZoomBadge: Bool
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
                    textColor: SIMD3<Float>,
                    showsZoomBadge: Bool = true) {
            self.enableDebugPanel = enableDebugPanel
            self.showsZoomBadge = showsZoomBadge
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
        /// Badge size preset. Scales fonts, paddings and the maximum badge
        /// width coherently; the concrete metrics live in the UI layer.
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
        /// The line renders at the given alpha, so a translucent badge is
        /// a colour with an alpha under 1.
        public var textColor: SIMD4<Float>?
        /// Whether the first credit on the line, the tile source's, leads:
        /// bold at the colour's alpha, the rest of the line at 76% of it.
        /// Off, the default, every credit is set the same way, as one
        /// list. Turn it on when the tile source's credit should stand out
        /// from the data credited beside it.
        public var emphasizesLeadingCredit: Bool
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
                    emphasizesLeadingCredit: Bool = false,
                    isProvidedExternally: Bool = false,
                    attributionOverride: ImmersiveMapAttribution? = nil) {
            self.isVisible = isVisible
            self.size = size
            self.position = position
            self.margin = margin
            self.textColor = textColor
            self.emphasizesLeadingCredit = emphasizesLeadingCredit
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
    /// The controls drawn over the map, see `ControlsSettings`.
    public var controls: ControlsSettings
    /// Models that take the place of the map's own buildings, see
    /// `ImmersiveMapLandmark`.
    public var landmarks: [ImmersiveMapLandmark]
    /// The archive the map loads building models from by tile: the hosted
    /// one by default (`ImmersiveMapTilesService.modelArchiveURL`), nil for
    /// a map without models. See `ModelArchiveSettings`.
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
                controls: ControlsSettings = ControlsSettings(),
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
        self.controls = controls
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
                             textColor: SIMD3<Float>(0.82, 0.36, 0.0)),
        modelArchive: ModelArchiveSettings(archiveURL: ImmersiveMapTilesService.modelArchiveURL)
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

    /// The animated zoom's half-life (`CameraSettings.animatedZoomHalfLife`).
    func animatedZoom(halfLife: Double) -> ImmersiveMapSettings {
        var settings = self
        settings.camera.animatedZoomHalfLife = halfLife
        return settings
    }

    func presentationSettings(_ presentation: PresentationSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.presentation = presentation
        return settings
    }

    /// The globe at low zoom on or off; off keeps the map a plane at every
    /// zoom. The handover's bounds are left as configured when omitted.
    func globe(isEnabled: Bool = true,
               airHandoverStart: Float? = nil,
               airHandoverEnd: Float? = nil) -> ImmersiveMapSettings {
        var settings = self
        settings.presentation.isGlobeEnabled = isEnabled
        if let airHandoverStart {
            settings.presentation.airHandoverStart = airHandoverStart
        }
        if let airHandoverEnd {
            settings.presentation.airHandoverEnd = airHandoverEnd
        }
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
    func groundFlattening(fromTileZoom: Int? = nil, grid: Int? = nil, gridByTileZoom: [Int: Int]? = nil) -> ImmersiveMapSettings {
        var settings = self
        if let fromTileZoom {
            settings.tiles.groundFlattening.fromTileZoom = fromTileZoom
        }
        if let grid {
            settings.tiles.groundFlattening.grid = grid
        }
        if let gridByTileZoom {
            settings.tiles.groundFlattening.gridByTileZoom = gridByTileZoom
        }
        return settings
    }

    /// The flattened ground raised by a heightmap
    /// (`TileSettings.GroundReliefSettings`), a nil leaving a value as
    /// configured.
    func groundRelief(isEnabled: Bool? = nil,
                      tileURLTemplate: String? = nil,
                      encoding: TileSettings.GroundReliefEncoding? = nil,
                      exaggeration: Float? = nil,
                      appearZoom: Double? = nil,
                      collapseZoom: Double? = nil,
                      transitionSeconds: TimeInterval? = nil,
                      cameraTerrainZoom: Int? = nil,
                      displacementMaximumZoom: Int? = nil,
                      maximumConcurrentLoads: Int? = nil,
                      releasedCacheBytes: Int? = nil,
                      cameraClearanceMetres: Float? = nil,
                      castsShadows: Bool? = nil) -> ImmersiveMapSettings {
        var settings = self
        if let castsShadows {
            settings.tiles.groundRelief.castsShadows = castsShadows
        }
        if let releasedCacheBytes {
            settings.tiles.groundRelief.releasedCacheBytes = max(0, releasedCacheBytes)
        }
        if let maximumConcurrentLoads {
            settings.tiles.groundRelief.maximumConcurrentLoads = max(1, maximumConcurrentLoads)
        }
        if let cameraTerrainZoom {
            settings.tiles.groundRelief.cameraTerrainZoom = max(0, cameraTerrainZoom)
        }
        if let displacementMaximumZoom {
            settings.tiles.groundRelief.displacementMaximumZoom = max(0, displacementMaximumZoom)
        }
        if let appearZoom {
            settings.tiles.groundRelief.appearZoom = appearZoom
        }
        if let collapseZoom {
            settings.tiles.groundRelief.collapseZoom = collapseZoom
        }
        if let transitionSeconds {
            settings.tiles.groundRelief.transitionSeconds = max(transitionSeconds, 0)
        }
        if let encoding {
            settings.tiles.groundRelief.encoding = encoding
        }
        if let isEnabled {
            settings.tiles.groundRelief.isEnabled = isEnabled
        }
        if let tileURLTemplate {
            settings.tiles.groundRelief.tileURLTemplate = tileURLTemplate
        }
        if let exaggeration {
            settings.tiles.groundRelief.exaggeration = exaggeration
        }
        if let cameraClearanceMetres {
            settings.tiles.groundRelief.cameraClearanceMetres = cameraClearanceMetres
        }
        return settings
    }

    /// How the country around the camera is read as mountains or a plain
    /// (`TileSettings.TerrainSurroundingsSettings`), a nil leaving a value
    /// as configured.
    func terrainSurroundings(sampleRadiusMetres: Float? = nil,
                             plainBelowMetres: Float? = nil,
                             mountainsAboveMetres: Float? = nil,
                             smoothingHalfLife: TimeInterval? = nil) -> ImmersiveMapSettings {
        var settings = self
        if let sampleRadiusMetres {
            settings.tiles.groundRelief.surroundings.sampleRadiusMetres = max(sampleRadiusMetres, 1)
        }
        if let plainBelowMetres {
            settings.tiles.groundRelief.surroundings.plainBelowMetres = max(plainBelowMetres, 0)
        }
        if let mountainsAboveMetres {
            settings.tiles.groundRelief.surroundings.mountainsAboveMetres = max(mountainsAboveMetres, 0)
        }
        if let smoothingHalfLife {
            settings.tiles.groundRelief.surroundings.smoothingHalfLife = max(smoothingHalfLife, 0)
        }
        return settings
    }

    /// The tiles drawn from a texture (`TileSettings.RasterizationSettings`),
    /// a nil leaving a value as configured.
    func tileRasterization(maximumAnisotropy: Int? = nil,
                           mipLevelBias: Float? = nil) -> ImmersiveMapSettings {
        var settings = self
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
        settings.tiles.groundFlattening.isEnabled = isEnabled
        return settings
    }

    /// The overview of the globe laid into the tiles of zooms 0 to 7, or
    /// not, and the camera zoom its credit stays on the attribution line
    /// up to (`TileSettings.OverviewSettings`). Nil leaves a field
    /// unchanged.
    func overviewTiles(isEnabled: Bool? = nil,
                       creditMaximumZoom: Double? = nil) -> ImmersiveMapSettings {
        var settings = self
        if let isEnabled {
            settings.tiles.overview.isEnabled = isEnabled
        }
        if let creditMaximumZoom {
            settings.tiles.overview.creditMaximumZoom = creditMaximumZoom
        }
        return settings
    }

    /// The deepest tile zoom level requested from the source. Past it the
    /// camera keeps zooming and the renderer scales the deepest tiles up.
    /// How many tiles are parsed at once
    /// (`TileSettings.ParsingSettings.maximumConcurrentParses`). An omitted
    /// value is left as configured.
    func tileParsing(maximumConcurrentParses: Int? = nil) -> ImmersiveMapSettings {
        var settings = self
        if let maximumConcurrentParses {
            settings.tiles.parsing.maximumConcurrentParses = max(1, maximumConcurrentParses)
        }
        return settings
    }

    /// The flat map's texture bands' margin past the visible ground
    /// (`TileSettings.CoverageSettings.rasterBandMarginShare`).
    func tileCoverage(rasterBandMarginShare: Float) -> ImmersiveMapSettings {
        var settings = self
        settings.tiles.coverage.rasterBandMarginShare = max(rasterBandMarginShare, 0)
        return settings
    }

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

    /// The sun on the globe (`GlobeLightSettings`), whole.
    func globeLightSettings(_ globeLight: GlobeLightSettings) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.globeLight = globeLight
        return settings
    }

    /// The sun on the globe on or off, and any of its values set in place,
    /// a nil leaving a value as configured.
    func globeLight(isEnabled: Bool = true,
                    subsolarLatitudeDegrees: Float? = nil,
                    subsolarLongitudeDegrees: Float? = nil,
                    strength: ImmersiveMapZoomCurve? = nil,
                    terminatorSoftness: Float? = nil,
                    nightColor: SIMD3<Float>? = nil) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.globeLight.isEnabled = isEnabled
        if let subsolarLatitudeDegrees {
            settings.scene.globeLight.subsolarLatitudeDegrees = subsolarLatitudeDegrees
        }
        if let subsolarLongitudeDegrees {
            settings.scene.globeLight.subsolarLongitudeDegrees = subsolarLongitudeDegrees
        }
        if let strength {
            settings.scene.globeLight.strength = strength
        }
        if let terminatorSoftness {
            settings.scene.globeLight.terminatorSoftness = terminatorSoftness
        }
        if let nightColor {
            settings.scene.globeLight.nightColor = nightColor
        }
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

    /// The map of a night, or of a day again: the night palette
    /// (`ProtomapsBasemapMapStyle.night`) with the night's air
    /// (`FogSettings.night`), the ground fog following the horizon, or the
    /// built-in style with the day's air. A change of style re-prepares
    /// the tiles, the air applies live.
    func night(_ isEnabled: Bool = true) -> ImmersiveMapSettings {
        var settings = self
        settings.mapStyle = AnyImmersiveMapMapStyle(isEnabled ? ProtomapsBasemapMapStyle.night : .default)
        settings.scene.fog = isEnabled ? .night : FogSettings()
        settings.scene.groundFog.color = nil
        return settings
    }

    /// The flat map's sky on or off. Off leaves the sky the clear colour.
    func fog(isEnabled: Bool = true) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.fog.isEnabled = isEnabled
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
                   veilsBuildings: Bool? = nil,
                   takesSkyColor: Bool? = nil,
                   heightsFromSeaLevel: Bool? = nil,
                   baseAltitudeMeters: Float? = nil) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.groundFog.isEnabled = isEnabled
        if let veilsBuildings {
            settings.scene.groundFog.veilsBuildings = veilsBuildings
        }
        if let takesSkyColor {
            settings.scene.groundFog.takesSkyColor = takesSkyColor
        }
        if let heightsFromSeaLevel {
            settings.scene.groundFog.heightsFromSeaLevel = heightsFromSeaLevel
        }
        if let baseAltitudeMeters {
            settings.scene.groundFog.baseAltitudeMeters = baseAltitudeMeters
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

    /// The air over the mountains (`SceneSettings.mountainGroundFog`): the
    /// one set so far (the default one, made of the default plain air), or
    /// a copy of the plain's air to start from where none is set, with the
    /// given values in place. A nil leaves a value as it is.
    func mountainGroundFog(isEnabled: Bool = true,
                           densityPerKilometer: ImmersiveMapZoomCurve? = nil,
                           heightMeters: ImmersiveMapZoomCurve? = nil,
                           startDistanceMeters: ImmersiveMapZoomCurve? = nil,
                           startSoftnessMeters: ImmersiveMapZoomCurve? = nil,
                           color: SIMD3<Float>? = nil,
                           maximumOpacity: ImmersiveMapZoomCurve? = nil,
                           veilsBuildings: Bool? = nil,
                           takesSkyColor: Bool? = nil,
                           heightsFromSeaLevel: Bool? = nil,
                           baseAltitudeMeters: Float? = nil) -> ImmersiveMapSettings {
        var settings = self
        var fog = scene.mountainGroundFog ?? scene.groundFog
        fog.isEnabled = isEnabled
        if let veilsBuildings {
            fog.veilsBuildings = veilsBuildings
        }
        if let takesSkyColor {
            fog.takesSkyColor = takesSkyColor
        }
        if let heightsFromSeaLevel {
            fog.heightsFromSeaLevel = heightsFromSeaLevel
        }
        if let baseAltitudeMeters {
            fog.baseAltitudeMeters = baseAltitudeMeters
        }
        if let densityPerKilometer {
            fog.densityPerKilometer = densityPerKilometer
        }
        if let heightMeters {
            fog.heightMeters = heightMeters
        }
        if let startDistanceMeters {
            fog.startDistanceMeters = startDistanceMeters
        }
        if let startSoftnessMeters {
            fog.startSoftnessMeters = startSoftnessMeters
        }
        if let color {
            fog.color = color
        }
        if let maximumOpacity {
            fog.maximumOpacity = maximumOpacity
        }
        settings.scene.mountainGroundFog = fog
        return settings
    }

    /// The air over the mountains as a whole, nil for one air everywhere.
    func mountainGroundFog(_ fog: GroundFogSettings?) -> ImmersiveMapSettings {
        var settings = self
        settings.scene.mountainGroundFog = fog
        return settings
    }

    /// The extruded buildings' zoom and the rise out of the ground
    /// (`ExtrusionSettings`), a nil leaving a value as configured.
    /// `risesFromTheGround` is the rise's switch, read after
    /// `riseSeconds`: off, a layer stands up at once, and on, it takes
    /// the configured time, or the default when the configured time is
    /// zero.
    func buildingExtrusion(buildingsMinimumZoom: Double? = nil,
                           riseSeconds: TimeInterval? = nil,
                           risesFromTheGround: Bool? = nil) -> ImmersiveMapSettings {
        var settings = self
        if let buildingsMinimumZoom {
            settings.scene.extrusion.buildingsMinimumZoom = buildingsMinimumZoom
        }
        if let riseSeconds {
            settings.scene.extrusion.riseSeconds = max(riseSeconds, 0)
        }
        if let risesFromTheGround {
            if risesFromTheGround {
                if settings.scene.extrusion.riseSeconds <= 0 {
                    settings.scene.extrusion.riseSeconds = ExtrusionSettings().riseSeconds
                }
            } else {
                settings.scene.extrusion.riseSeconds = 0
            }
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
                             emphasizesLeadingCredit: Bool? = nil,
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
        if let emphasizesLeadingCredit {
            attribution.emphasizesLeadingCredit = emphasizesLeadingCredit
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
    /// hosted service's credit, which is what the default source requires,
    /// and after either the credit of the overview the engine lays into the
    /// tiles while it is on (`OverviewTileSource.credit`, at the zooms up to
    /// `TileSettings.OverviewSettings.creditMaximumZoom`), then the credit
    /// of Mapterhorn's terrain at the zooms the relief rises at
    /// (`GroundReliefSettings.credit`). An app that points the map at its
    /// own data owns the credit of that data and states it with
    /// `attributionSettings`. An empty override is the app taking the whole
    /// credit, the overview's and the terrain's with it, off the badge: the
    /// badge stays empty and the hidden-attribution warning stands.
    var resolvedAttribution: ImmersiveMapAttribution {
        var resolved = attribution.attributionOverride ?? ImmersiveMapTilesService.attribution
        guard resolved.isEmpty == false else {
            return resolved
        }
        if tiles.overview.isEnabled {
            resolved = resolved.appending(OverviewTileSource.credit(maximumZoom: tiles.overview.creditMaximumZoom))
        }
        if let reliefCredit = tiles.groundRelief.credit {
            resolved = resolved.appending(reliefCredit)
        }
        return resolved
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

    /// The debug panel on or off, and its zoom badge
    /// (`DebugSettings.showsZoomBadge`), a nil leaving it as configured.
    func debugPanel(_ isEnabled: Bool = true, zoomBadge: Bool? = nil) -> ImmersiveMapSettings {
        var settings = self
        settings.debug.enableDebugPanel = isEnabled
        if let zoomBadge {
            settings.debug.showsZoomBadge = zoomBadge
        }
        return settings
    }

    /// Every control drawn over the map hidden, or shown again
    /// (`ControlsSettings.isHidden`).
    func controlsHidden(_ isHidden: Bool = true) -> ImmersiveMapSettings {
        var settings = self
        settings.controls.isHidden = isHidden
        return settings
    }

}
