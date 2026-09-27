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
        cameraState.pitch = settings.clampPitch(cameraState.pitch, at: cameraState.zoom)
        constrainCenterToBounds()
    }

    convenience init(config: ImmersiveMapSettings) {
        self.init(settings: config.camera)
    }

    func apply(settings: ImmersiveMapSettings.CameraSettings) {
        self.settings = settings
        cameraState.zoom = settings.clampZoom(cameraState.zoom)
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
        let sensitivity = settings.worldPanSensitivity / pow(2.0, zoom)

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
        setCenterWorldMercator(proposedCenter)
    }

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
        constrainCenterToBounds()
    }

    private func applyZoomDelta(_ delta: Double) {
        guard delta.isFinite else {
            return
        }

        cameraState.zoom += delta
        cameraState.zoom = settings.clampZoom(cameraState.zoom)
        constrainCenterToBounds()
    }
}
