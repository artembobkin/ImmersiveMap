// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

class CameraStateController {
    private(set) var cameraState: ImmersiveMapCameraState = .default
    private var settings: ImmersiveMapSettings.CameraSettings {
        didSet {
            boundsConstraint = settings.bounds.map(CameraBoundsConstraint.init(bounds:))
        }
    }
    private var boundsConstraint: CameraBoundsConstraint?
    /// The terrain the camera looks at (`CameraTerrainFollow`), nil on a
    /// map without a relief: a pan keeps the eye's height by the zoom, and
    /// the zoom stops at the clearance over the terrain.
    var terrainFollow: CameraTerrainFollow?
    /// How the last move over the terrain was settled, for the debug panel
    /// (`TerrainFollowReport`). Nil before any, or off the terrain.
    private(set) var lastTerrainFollowReport: TerrainFollowReport?
    /// Which path the last settle took (`settleOnTerrain`).
    private var lastSettlePath: TerrainFollowReport.Path = .hit
    /// The zoom the map is planned by: the zoom of the coverage's target
    /// tiles and the ring rules (`RenderFrameVisibilityResolver`) and of
    /// the relief's thresholds (`GroundReliefStore`). It moves only when
    /// the zoom is set on purpose, and then takes the camera's zoom as it
    /// comes out: a zoom gesture, or a zoom set outright (`setZoom`,
    /// `setCameraPosition`, `setCameraState`). Over the terrain the
    /// camera's zoom also follows the ground the camera looks at
    /// (`followTerrain`), deeper up a slope and shallower down one, and
    /// backs off over a ridge (`clearedZoom`), and none of that moves
    /// this zoom: a map planned by the zoom of the moment would reshuffle
    /// its rings with every slope a drag crosses, and a relief faded by
    /// it would breathe. The two zooms part by the terrain climbed since
    /// the last zoom and meet again at the next: not by a delta, which
    /// would carry the climb along and leave the map planned levels away
    /// from what the camera sees after a zoom back.
    private(set) var planningZoom: Double = ImmersiveMapCameraState.default.zoom
    /// The zoom a drag over the terrain moves the map by: the camera's
    /// zoom at the drag's start, held to its end (`endPan`), nil between
    /// drags. The camera's zoom follows the ground through the drag, and
    /// a drag moved by the zoom of the moment would slow on the way up a
    /// slope and hurry on the way down.
    private var dragZoom: Double?

    var globePan: SIMD2<Double> {
        ImmersiveMapProjection.globePan(fromCenterWorldMercator: cameraState.centerWorldMercator)
    }

    var flatPan: SIMD2<Double> {
        ImmersiveMapProjection.flatPan(fromCenterWorldMercator: cameraState.centerWorldMercator)
    }

    var yaw: Float {
        cameraState.bearing
    }

    var pitch: Float {
        cameraState.pitch
    }

    var zoom: Double {
        cameraState.zoom
    }

    init(settings: ImmersiveMapSettings.CameraSettings) {
        self.settings = settings
        self.boundsConstraint = settings.bounds.map(CameraBoundsConstraint.init(bounds:))
        // The default state starts at zoom 0 and pitch 0; a configured
        // minimumZoom, minimumPitch or region must hold from the very first
        // frame, not from the first gesture.
        cameraState.zoom = settings.clampZoom(cameraState.zoom)
        planningZoom = settings.clampZoom(planningZoom)
        cameraState.pitch = settings.clampPitch(cameraState.pitch, at: cameraState.zoom)
        constrainCenterToBounds()
    }

    convenience init(config: ImmersiveMapSettings) {
        self.init(settings: config.camera)
    }

    func apply(settings: ImmersiveMapSettings.CameraSettings) {
        self.settings = settings
        cameraState.zoom = settings.clampZoom(cameraState.zoom)
        planningZoom = settings.clampZoom(planningZoom)
        cameraState.pitch = settings.clampPitch(cameraState.pitch, at: cameraState.zoom)
        constrainCenterToBounds()
    }

    /// The horizontal latitude pan compensation ramps in as the camera zooms in:
    /// below start there is none, above end it is full.
    private static let horizontalPanCompensationStartZoom = 2.5
    private static let horizontalPanCompensationEndZoom = 5.0

    /// Shifts the map center by the gesture delta. `transition` is the globe-to-flat
    /// phase (0 = globe, 1 = flat). On the sphere a screen point covers
    /// `1 / cos(latitude)` more Mercator than on the plane at the same camera
    /// distance, and the camera's globe proximity (`GlobeCameraProximity`)
    /// moves in by the same scale: the Mercator delta per point is the
    /// proximity factor over the surface scale, which is 1 once the
    /// proximity is fully in, and the old `1 / cos` below its activation.
    ///
    /// Vertically the compensation is full at any zoom. Horizontally, near a pole
    /// a swipe is a rotation around the view axis: at low zooms (the whole globe
    /// is visible) full compensation turns it into uncontrollable spinning,
    /// so the horizontal factor is ramped in smoothly by zoom.
    func pan(deltaX: Double, deltaY: Double, transition: Float) {
        let yaw = Double(cameraState.bearing)
        let startForward = SIMD2<Double>(0, 1)
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: cameraState.centerWorldMercator.y)
        let surfaceScale = SurfaceScaleMath.surfaceScale(latitude: latitude, transition: transition)
        let proximity = GlobeCameraProximity.distanceFactor(latitude: latitude, transition: transition, zoom: zoom)
        let onTerrain = transition >= 1 && terrainFollow != nil
        let panZoom: Double
        if onTerrain {
            panZoom = dragZoom ?? zoom
            dragZoom = panZoom
        } else {
            panZoom = zoom
        }
        let sensitivity = settings.worldPanSensitivity / pow(2.0, panZoom)

        let cosYaw = cos(-yaw)
        let sinYaw = sin(-yaw)
        let forward = SIMD2<Double>(
            startForward.x * cosYaw - startForward.y * sinYaw,
            startForward.x * sinYaw + startForward.y * cosYaw
        )
        let right = -1 * SIMD2<Double>(
            -forward.y, forward.x
        )

        let panDelta = sensitivity * (forward * deltaY * settings.worldPanSpeed + right * deltaX * settings.worldPanSpeed)
        let verticalCompensation = proximity / surfaceScale
        let horizontalCompensation = 1.0 + (verticalCompensation - 1.0) * horizontalCompensationRamp(zoom: zoom)
        let worldDelta = SIMD2<Double>(-0.5 * panDelta.x * horizontalCompensation,
                                       -0.5 * panDelta.y * verticalCompensation)
        let proposedCenter = cameraState.centerWorldMercator + worldDelta
        if let boundsConstraint, let maximumStretchPoints = elasticMaximumStretchPoints {
            cameraState.centerWorldMercator = boundsConstraint.resist(from: cameraState.centerWorldMercator,
                                                                      to: proposedCenter,
                                                                      zoom: zoom,
                                                                      maximumStretch: maximumStretchPoints * worldPerPoint)
            return
        }
        if transition >= 1, let terrainFollow {
            let followed = followTerrain(from: cameraState.centerWorldMercator, to: proposedCenter, follow: terrainFollow)
            cameraState.zoom = clearedZoom(followed.zoom, center: followed.center, follow: terrainFollow)
            recordTerrainFollow(followedZoom: followed.zoom, center: followed.center, follow: terrainFollow)
            setCenterWorldMercator(followed.center)
            return
        }
        setCenterWorldMercator(proposedCenter)
    }

    /// The zoom, or the shallower one that keeps the eye its clearance
    /// over the terrain under it (`CameraTerrainFollow.clearZoom`): over
    /// a ridge between the eye and the point the eye backs off along its
    /// view ray, by the arm, rather than being lifted off its pose. The
    /// zoom does not come back on its own past the ridge, so the camera's
    /// own motion is all the eye ever feels.
    private func clearedZoom(_ zoom: Double, center: SIMD2<Double>, follow: CameraTerrainFollow) -> Double {
        follow.clearZoom(below: zoom,
                         center: center,
                         pitch: cameraState.pitch,
                         bearing: cameraState.bearing,
                         range: settings.minimumZoom ... settings.maximumZoom)
    }

    /// The drag ended: the next one moves the map by the zoom it starts at
    /// (`dragZoom`).
    func endPan() {
        dragZoom = nil
    }

    /// The report of a move just settled: the path the settle took, the
    /// arm at the zoom it answered, and how far the clearance lowered
    /// that zoom (`clearedZoom`, applied to `cameraState.zoom` already).
    private func recordTerrainFollow(followedZoom: Double, center: SIMD2<Double>, follow: CameraTerrainFollow) {
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: center.y)
        let arm = CameraTerrainFollow.eyeDistanceMetres(zoom: followedZoom, latitude: latitude, globeRadiusScale: follow.globeRadiusScale)
        lastTerrainFollowReport = TerrainFollowReport(path: lastSettlePath,
                                                      armMetres: arm,
                                                      clearedZoomDelta: cameraState.zoom - followedZoom)
    }

    /// A pan over the terrain: the eye moves over the map by the pan, from
    /// over `from` to over `to` as the plain pan would move the point it
    /// looks at, and keeps its altitude. The point it looks at is where
    /// its view ray, pitched as the pose is, meets the terrain from there:
    /// the zoom is the arm to that point, deeper up a slope and shallower
    /// down one, never under the clearance. Moving the point by the pan
    /// instead would move the eye by the pan less the arm's change along
    /// the view, a drag that drifts with the ground's rise and fall under
    /// a pitched camera. The ray's meeting with the terrain is found by
    /// marching along it and bisecting the first crossing, which settles
    /// on any slope, steeper than the ray included. Where the terrain
    /// along the ray is not known yet, or the ray meets none within reach
    /// (the eye under the terrain, or the ground fallen out of the zoom's
    /// range), the point goes where the pan puts it and the zoom keeps the
    /// altitude as far as it can.
    func followTerrain(from: SIMD2<Double>,
                       to: SIMD2<Double>,
                       follow: CameraTerrainFollow) -> (center: SIMD2<Double>, zoom: Double) {
        guard let heightFrom = follow.terrainMetres(from) else {
            return (to, cameraState.zoom)
        }
        let pitch = cameraState.pitch
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: from.y)
        let eyeAltitude = Double(heightFrom) + follow.eyeHeightMetres(zoom: cameraState.zoom, pitch: pitch, latitude: latitude)
        let reach = follow.eyeReachMetres(zoom: cameraState.zoom, pitch: pitch, latitude: latitude)
        let metresPerWorld = ImmersiveMapProjection.earthCircumferenceMeters * max(cos(latitude), 1e-6)
        let forward = CameraTerrainFollow.forward(bearing: cameraState.bearing)
        let eyeGround = to - forward * (reach / metresPerWorld)
        return settleOnTerrain(eyeAltitude: eyeAltitude,
                               eyeGround: eyeGround,
                               reach: reach,
                               fallbackCenter: to,
                               follow: follow)
    }

    /// A zoom over the terrain, by the same rule as a pan: the eye moves
    /// along its view ray by the zoom, nearer the point it looks at or
    /// farther from it, and from where it lands the point is where the
    /// ray meets the terrain. The terrain the ray meets is the terrain
    /// the new zoom reads, which at a zoom crossing is another map, one
    /// level coarser or finer: read where the point was, it stands higher
    /// or lower than the old one did, and were the point kept and the
    /// relief redrawn from under it, the eye would jump with the
    /// difference, a bump at every crossing of a fast zoom. The eye stays
    /// where the zoom put it, the point moves along the ray by the
    /// difference and the zoom, the arm, takes it up. Nothing moves when
    /// the terrain under the point reads as before.
    func followTerrainZoom(from previousZoom: Double,
                           heightBefore: Float,
                           follow: CameraTerrainFollow) -> (center: SIMD2<Double>, zoom: Double) {
        let center = cameraState.centerWorldMercator
        let zoom = cameraState.zoom
        guard let heightAfter = follow.terrainMetres(center), abs(heightAfter - heightBefore) > 1e-3 else {
            return (center, zoom)
        }
        let pitch = cameraState.pitch
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: center.y)
        let eyeAltitude = Double(heightBefore) + follow.eyeHeightMetres(zoom: zoom, pitch: pitch, latitude: latitude)
        let reach = follow.eyeReachMetres(zoom: zoom, pitch: pitch, latitude: latitude)
        let metresPerWorld = ImmersiveMapProjection.earthCircumferenceMeters * max(cos(latitude), 1e-6)
        let forward = CameraTerrainFollow.forward(bearing: cameraState.bearing)
        let eyeGround = center - forward * (reach / metresPerWorld)
        // The march steps by a part of the old reach, as the pan's does.
        let oldReach = follow.eyeReachMetres(zoom: previousZoom, pitch: pitch, latitude: latitude)
        return settleOnTerrain(eyeAltitude: eyeAltitude,
                               eyeGround: eyeGround,
                               reach: max(reach, oldReach),
                               fallbackCenter: center,
                               follow: follow)
    }

    /// Where the view ray of an eye `eyeAltitude` metres up over
    /// `eyeGround`, pitched and turned as the pose is, meets the terrain,
    /// and the zoom that puts the eye there: the ray is marched in steps
    /// of a part of `reach` and its first crossing bisected, which settles
    /// on any slope, steeper than the ray included. Where the terrain
    /// along the ray is not known yet, or the ray meets none within
    /// reach, the point is `fallbackCenter` and the zoom keeps the
    /// altitude over it as far as it can.
    private func settleOnTerrain(eyeAltitude: Double,
                                 eyeGround: SIMD2<Double>,
                                 reach: Double,
                                 fallbackCenter to: SIMD2<Double>,
                                 follow: CameraTerrainFollow) -> (center: SIMD2<Double>, zoom: Double) {
        let pitch = cameraState.pitch
        let zoomRange = max(settings.minimumZoom, 0) ... settings.maximumZoom
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: to.y)
        let metresPerWorld = ImmersiveMapProjection.earthCircumferenceMeters * max(cos(latitude), 1e-6)
        let forward = CameraTerrainFollow.forward(bearing: cameraState.bearing)
        let tanPitch = Double(tan(pitch))
        // How far past the ray the terrain is at `r` metres ahead of the
        // eye: the ray at that reach is `r / tan(pitch)` under the eye,
        // and it has met the terrain once the terrain is at least that
        // far under it, that is, once r >= (altitude - terrain) * tan.
        // Nil where the terrain is not known.
        func crossing(_ r: Double) -> Double? {
            follow.terrainMetres(eyeGround + forward * (r / metresPerWorld)).map { r - (eyeAltitude - Double($0)) * tanPitch }
        }
        // The fallback keeps the arm: the point goes where the pan puts it
        // and the zoom stays, so a frame the ray cannot be settled on (the
        // eye under the terrain, the terrain not known, no ground within
        // reach) moves the camera the plain way and changes nothing else.
        // A zoom read off the ground under the point instead jumped: an
        // eye a hair under a crest read a height of nothing over the
        // crest's own top and the zoom went to its limit.
        let fallback = { () -> (center: SIMD2<Double>, zoom: Double) in
            self.lastSettlePath = .fallback
            return (to, self.cameraState.zoom)
        }
        // The eye is over the terrain under it, to within a metre: an eye
        // skimming a crest at a clearance of nothing is a hair over or
        // under it from frame to frame, and the hair must not pick the
        // path.
        guard let start = crossing(0), start <= tanPitch * Self.eyeOverGroundToleranceMetres else {
            return fallback()
        }
        lastSettlePath = .hit
        // The march: the ray is tried further and further ahead, one
        // terrain texel at a time (`CameraTerrainFollow.sampleStepWorld`),
        // as far as eight times the old reach, which is where the ground
        // would have fallen out of the zoom's range anyway. By the texel,
        // not by the zoom: a step that grew with the reach found a ridge
        // at one zoom and stepped over it at the next, and the camera
        // shook between the two answers. A far reach caps the samples and
        // coarsens the step instead. The march always takes its first
        // sample: a camera looking straight down has no reach, and a
        // march that went nowhere fell back to the plain pan, so the eye
        // rode the hills it looked down on.
        let texelStep = max(follow.sampleStepWorld * metresPerWorld, 0.5)
        let farthest = max(reach * 8, texelStep)
        let step = max(texelStep, farthest / Double(Self.marchSampleLimit))
        var lowReach = 0.0
        var highReach: Double?
        var r = step
        while r <= farthest {
            guard let value = crossing(r) else {
                return fallback()
            }
            if value >= 0 {
                highReach = r
                break
            }
            lowReach = r
            r += step
        }
        guard var high = highReach else {
            return fallback()
        }
        // The crossing, to within a tenth of a metre.
        for _ in 0 ..< 24 where high - lowReach > 0.1 {
            let middle = (lowReach + high) * 0.5
            guard let value = crossing(middle) else {
                return fallback()
            }
            if value >= 0 {
                high = middle
            } else {
                lowReach = middle
            }
        }
        let center = eyeGround + forward * (high / metresPerWorld)
        guard let heightTo = follow.terrainMetres(center) else {
            return fallback()
        }
        let latitudeTo = ImmersiveMapProjection.latitude(fromNormalizedWorldY: center.y)
        let height = max(eyeAltitude - Double(heightTo), follow.clearanceMetres)
        return (center, follow.zoom(forEyeHeightMetres: height, pitch: pitch, latitude: latitudeTo, range: zoomRange))
    }

    /// The most samples the march takes along the ray: a reach far past
    /// what the texel's step covers in that many is marched coarser.
    static let marchSampleLimit = 1024
    /// How far under the terrain the eye may be read and still be over it
    /// (`settleOnTerrain`).
    static let eyeOverGroundToleranceMetres = 1.0

    /// The fastest the elastic pull gets, as a multiple of its rate at the
    /// edge: a center far out, after a jump or a deep zoom, still glides in
    /// over a few tenths of a second instead of teleporting.
    private static let maximumPullGrowth = 16.0

    /// One frame of the elastic edge's pull: moves the center toward the
    /// area by the share of the way the pull covers in `deltaTime` at the
    /// center's distance (see `Bounds.EdgeBehavior.elastic`), and snaps it
    /// in once it is within a twentieth of a screen point. Returns whether
    /// the center is still outside, false at once for a center inside the
    /// area, a hard edge or no bounds.
    func advanceBoundsPull(deltaTime: Double) -> Bool {
        guard let boundsConstraint,
              case .elastic(let maximumStretch, let pullHalfLife, let pullProgression) = settings.bounds?.edgeBehavior else {
            return false
        }

        let center = cameraState.centerWorldMercator
        let distancePoints = boundsConstraint.distanceOutside(of: center, zoom: zoom) / worldPerPoint
        let growth: Double
        if maximumStretch > 0, pullProgression > 0 {
            growth = min(pow(1 + distancePoints / maximumStretch, pullProgression), Self.maximumPullGrowth)
        } else {
            growth = 1
        }
        let rate = pullHalfLife > 0 ? log(2.0) / pullHalfLife * growth : .infinity
        let fraction = 1 - exp(-rate * max(deltaTime, 0))
        let step = boundsConstraint.returnStep(from: center,
                                               zoom: zoom,
                                               fraction: fraction.isFinite ? fraction : 1)
        guard step.remainingDistance > worldPerPoint * 0.05 else {
            let settled = boundsConstraint.apply(to: cameraState.centerWorldMercator, zoom: zoom)
            if settled != cameraState.centerWorldMercator {
                cameraState.centerWorldMercator = settled
            }
            return false
        }

        cameraState.centerWorldMercator = step.center
        return true
    }

    /// How far a screen point of drag moves the center at the current zoom:
    /// the pan's sensitivity chain before the surface compensation, which is
    /// close enough for the elastic edge's reach and its settling distance.
    private var worldPerPoint: Double {
        abs(0.5 * settings.worldPanSensitivity * settings.worldPanSpeed * settings.gesturePanTranslationScale)
            / pow(2.0, zoom)
    }

    /// The elastic edge's reach in screen points, nil for a hard edge or no
    /// bounds.
    private var elasticMaximumStretchPoints: Double? {
        guard case .elastic(let maximumStretch, _, _) = settings.bounds?.edgeBehavior else {
            return nil
        }
        return maximumStretch.isFinite ? max(maximumStretch, 0) : 0
    }

    private func horizontalCompensationRamp(zoom: Double) -> Double {
        let start = Self.horizontalPanCompensationStartZoom
        let end = Self.horizontalPanCompensationEndZoom
        let progress = min(max((zoom - start) / (end - start), 0.0), 1.0)
        return progress * progress * (3.0 - 2.0 * progress)
    }

    func setZoom(zoom: Double) {
        applyZoomDelta(zoom - cameraState.zoom)
    }

    func setCenterWorldMercator(_ centerWorldMercator: SIMD2<Double>) {
        cameraState.centerWorldMercator = SIMD2<Double>(ImmersiveMapProjection.wrapNormalizedWorldX(centerWorldMercator.x),
                                                        ImmersiveMapProjection.clampNormalizedWorldY(centerWorldMercator.y))
        constrainCenterToBounds()
    }

    /// The center moved by a zoom's anchor compensation, the shift that
    /// keeps the world point under the cursor under it
    /// (`ImmersiveMapCameraRuntime.applyZoomAnchorCompensation`): over the
    /// terrain the move is a pan's (`followTerrain`). The point slides
    /// over the ground at every step of an anchored zoom, and the terrain
    /// under it, the datum the relief is drawn from, rises and falls with
    /// the ground it slides over. Set plainly, the whole relief would be
    /// redrawn from the new height under the eye, which rode every bump
    /// of the slide. The eye instead keeps the altitude the zoom gave it,
    /// the point is where its view ray meets the terrain, and the
    /// difference goes into the zoom, the arm. Off the terrain it is the
    /// plain set.
    func setCenterWorldMercatorOverTerrain(_ centerWorldMercator: SIMD2<Double>) {
        guard let terrainFollow else {
            setCenterWorldMercator(centerWorldMercator)
            return
        }
        let followed = followTerrain(from: cameraState.centerWorldMercator, to: centerWorldMercator, follow: terrainFollow)
        cameraState.zoom = clearedZoom(followed.zoom, center: followed.center, follow: terrainFollow)
        setCenterWorldMercator(followed.center)
    }

    /// A hard edge holds the center after every change of the center or the
    /// zoom, since the area closes in as the zoom grows. An elastic edge
    /// leaves it: the pan resists on its own, and the animation runtime
    /// brings the camera back once nothing moves it.
    private func constrainCenterToBounds() {
        guard let boundsConstraint,
              settings.bounds?.edgeBehavior == .hard else {
            return
        }

        cameraState.centerWorldMercator = boundsConstraint.apply(to: cameraState.centerWorldMercator,
                                                                 zoom: cameraState.zoom)
    }

    func setLatLonDeg(latDeg: Double, lonDeg: Double) {
        precondition(latDeg.isFinite && lonDeg.isFinite, "Latitude/longitude must be finite.")
        let maxLatitudeDeg = ImmersiveMapProjection.maxMercatorLatitude * (180.0 / .pi)
        precondition(abs(latDeg) <= maxLatitudeDeg, "Latitude out of range for Mercator: \(latDeg)")
        let globeLat = (latDeg / 180.0) * Double.pi
        let longitude = (lonDeg / 180.0) * Double.pi
        setCenterWorldMercator(ImmersiveMapProjection.worldMercator(latitude: globeLat, longitude: longitude))
    }

    func getLatLonDegGlobe() -> (latDeg: Double, lonDeg: Double) {
        let latLon = getLatLonRad()
        let latDeg = latLon.latRad * (180.0 / .pi)
        let lonDeg = latLon.lonRad * (180.0 / .pi)
        return (latDeg, lonDeg)
    }

    func getLatLonDegFlat() -> (latDeg: Double, lonDeg: Double) {
        getLatLonDegGlobe()
    }

    func getLatLonRadGlobe() -> (latRad: Double, lonRad: Double) {
        getLatLonRad()
    }

    func getLatLonRad() -> (latRad: Double, lonRad: Double) {
        let latRad = ImmersiveMapProjection.latitude(fromNormalizedWorldY: cameraState.centerWorldMercator.y)
        let lonRad = ImmersiveMapProjection.longitude(fromNormalizedWorldX: cameraState.centerWorldMercator.x)
        return (latRad, lonRad)
    }

    func getLatLonRadFlat() -> (latRad: Double, lonRad: Double) {
        getLatLonRad()
    }

    func getLatLonDeg() -> (latDeg: Double, lonDeg: Double) {
        let latLon = getLatLonRad()
        return (latLon.latRad * (180.0 / .pi),
                latLon.lonRad * (180.0 / .pi))
    }

    func getLatLonDeg(viewMode: ViewMode) -> (latDeg: Double, lonDeg: Double) {
        _ = viewMode
        return getLatLonDeg()
    }

    func getLatLonRad(viewMode: ViewMode) -> (latRad: Double, lonRad: Double) {
        _ = viewMode
        return getLatLonRad()
    }

    func rotateYaw(delta: Float) {
        cameraState.bearing += delta
    }

    func setBearing(_ bearing: Float) {
        cameraState.bearing = bearing
    }

    func clampBearing(to constraint: CameraBearingConstraint) {
        let constrainedBearing = constraint.apply(to: cameraState.bearing)
        guard constrainedBearing != cameraState.bearing else {
            return
        }

        cameraState.bearing = constrainedBearing
    }

    func clampPitch(to constraint: CameraPitchConstraint) {
        let constrainedPitch = constraint.apply(to: cameraState.pitch)
        guard constrainedPitch != cameraState.pitch else {
            return
        }

        cameraState.pitch = constrainedPitch
    }

    func setPitch(_ pitch: Float) {
        cameraState.pitch = settings.clampPitch(pitch, at: cameraState.zoom)
    }

    func zoom(scale: Double, velocity: Double = 0) {
        applyZoomDelta(PinchZoomMath.zoomDelta(scale: scale,
                                               velocity: velocity,
                                               pinchZoomFactor: settings.pinchZoomFactor,
                                               pinchZoomVelocityFactor: settings.pinchZoomVelocityFactor,
                                               pinchZoomVelocityLimit: settings.pinchZoomVelocityLimit))
    }

    func zoom(delta: Double) {
        applyZoomDelta(delta)
    }

    func setCameraPosition(_ cameraPosition: ImmersiveMapCameraPosition) {
        precondition(cameraPosition.latitudeDegrees.isFinite &&
                     cameraPosition.longitudeDegrees.isFinite &&
                     cameraPosition.zoom.isFinite &&
                     cameraPosition.bearing.isFinite &&
                     cameraPosition.pitch.isFinite,
                     "Camera position values must be finite.")

        let maxLatitudeDeg = ImmersiveMapProjection.maxMercatorLatitude * (180.0 / .pi)
        precondition(abs(cameraPosition.latitudeDegrees) <= maxLatitudeDeg,
                     "Latitude out of range for Mercator: \(cameraPosition.latitudeDegrees)")

        let latitudeRadians = (cameraPosition.latitudeDegrees / 180.0) * Double.pi
        let longitudeRadians = (cameraPosition.longitudeDegrees / 180.0) * Double.pi
        cameraState.centerWorldMercator = ImmersiveMapProjection.worldMercator(latitude: latitudeRadians,
                                                                      longitude: longitudeRadians)
        cameraState.zoom = settings.clampZoom(cameraPosition.zoom)
        planningZoom = cameraState.zoom
        cameraState.bearing = cameraPosition.bearing
        cameraState.pitch = settings.clampPitch(cameraPosition.pitch, at: cameraState.zoom)
        constrainCenterToBounds()
    }

    func currentCameraState() -> ImmersiveMapCameraState {
        cameraState
    }

    func setCameraState(_ cameraState: ImmersiveMapCameraState) {
        let clampedZoom = settings.clampZoom(cameraState.zoom)
        self.cameraState = ImmersiveMapCameraState(centerWorldMercator: cameraState.centerWorldMercator,
                                          zoom: clampedZoom,
                                          bearing: cameraState.bearing,
                                          pitch: settings.clampPitch(cameraState.pitch, at: clampedZoom))
        planningZoom = clampedZoom
        constrainCenterToBounds()
    }

    private func applyZoomDelta(_ delta: Double) {
        guard delta.isFinite else {
            return
        }

        let previousZoom = cameraState.zoom
        // The terrain under the point as the old zoom reads it, before
        // the new one reads another map (`followTerrainZoom`): the same
        // map at every zoom (`GroundReliefSettings.cameraTerrainZoom`),
        // so nothing moves unless the zoom crosses onto the plane.
        let heightBefore = terrainFollow?.terrainMetres(cameraState.centerWorldMercator)
        cameraState.zoom += delta
        cameraState.zoom = settings.clampZoom(cameraState.zoom)
        if let terrainFollow {
            if let heightBefore {
                let followed = followTerrainZoom(from: previousZoom, heightBefore: heightBefore, follow: terrainFollow)
                cameraState.zoom = followed.zoom
                cameraState.centerWorldMercator = followed.center
            }
            // Over a terrain the zoom stops where the eye would come
            // nearer than the clearance to the ground under it.
            let followedZoom = cameraState.zoom
            cameraState.zoom = clearedZoom(cameraState.zoom, center: cameraState.centerWorldMercator, follow: terrainFollow)
            recordTerrainFollow(followedZoom: followedZoom, center: cameraState.centerWorldMercator, follow: terrainFollow)
        }
        // A zoom on purpose: the map is planned by what the camera sees.
        planningZoom = cameraState.zoom
        constrainCenterToBounds()
    }
}

/// How the camera's last move over the terrain was settled
/// (`CameraStateController.lastTerrainFollowReport`), for the debug panel:
/// whether the view ray met the terrain or the move fell back to the plain
/// pan, the arm the settle answered with, and how far the clearance over
/// the ridge under the eye lowered that zoom afterwards.
struct TerrainFollowReport: Equatable {
    enum Path: String {
        case hit
        case fallback
    }

    let path: Path
    /// The eye's distance from the point it looks at, in metres.
    let armMetres: Double
    /// The zoom after the clearance less the zoom the settle answered,
    /// zero or negative.
    let clearedZoomDelta: Double
}
