// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import simd

class CameraStateController {
    private(set) var cameraState: ImmersiveMapCameraState = .default
    private var settings: ImmersiveMapSettings.CameraSettings

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
    }

    convenience init(config: ImmersiveMapSettings) {
        self.init(settings: config.camera)
    }

    func apply(settings: ImmersiveMapSettings.CameraSettings) {
        self.settings = settings
        cameraState.zoom = min(max(0, cameraState.zoom), settings.maximumZoom)
        cameraState.pitch = min(max(0, cameraState.pitch), settings.maximumReachablePitch(at: cameraState.zoom))
    }

    func pan(deltaX: Double, deltaY: Double) {
        let yaw = Double(cameraState.bearing)
        let startForward = SIMD2<Double>(0, 1)
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
        let worldDelta = SIMD2<Double>(-0.5 * panDelta.x, -0.5 * panDelta.y)
        setCenterWorldMercator(cameraState.centerWorldMercator + worldDelta)
    }

    func setZoom(zoom: Double) {
        applyZoomDelta(zoom - cameraState.zoom)
    }

    func setCenterWorldMercator(_ centerWorldMercator: SIMD2<Double>) {
        cameraState.centerWorldMercator = SIMD2<Double>(ImmersiveMapProjection.wrapNormalizedWorldX(centerWorldMercator.x),
                                                        ImmersiveMapProjection.clampNormalizedWorldY(centerWorldMercator.y))
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
        cameraState.pitch = min(max(0, pitch), settings.maximumReachablePitch(at: cameraState.zoom))
    }

    func rotatePitch(pitch: Float) {
        setPitch(settings.maximumPitch - pitch)
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
        cameraState.zoom = min(max(0, cameraPosition.zoom), settings.maximumZoom)
        cameraState.bearing = cameraPosition.bearing
        cameraState.pitch = min(max(0, cameraPosition.pitch), settings.maximumReachablePitch(at: cameraState.zoom))
    }

    func currentCameraState() -> ImmersiveMapCameraState {
        cameraState
    }

    func setCameraState(_ cameraState: ImmersiveMapCameraState) {
        let clampedZoom = min(max(0, cameraState.zoom), settings.maximumZoom)
        self.cameraState = ImmersiveMapCameraState(centerWorldMercator: cameraState.centerWorldMercator,
                                          zoom: clampedZoom,
                                          bearing: cameraState.bearing,
                                          pitch: min(max(0, cameraState.pitch), settings.maximumReachablePitch(at: clampedZoom)))
    }

    private func applyZoomDelta(_ delta: Double) {
        guard delta.isFinite else {
            return
        }

        cameraState.zoom += delta
        cameraState.zoom = min(max(0, cameraState.zoom), settings.maximumZoom)
    }
}
