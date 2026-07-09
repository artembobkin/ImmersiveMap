// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  ImmersiveMapCameraState.swift
//  ImmersiveMap
//

import simd

struct ImmersiveMapCameraState {
    static let `default` = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                          zoom: 0,
                                          bearing: 0,
                                          pitch: 0)

    var centerWorldMercator: SIMD2<Double>
    var zoom: Double
    var bearing: Float
    var pitch: Float

    init(centerWorldMercator: SIMD2<Double>,
         zoom: Double,
         bearing: Float,
         pitch: Float) {
        self.centerWorldMercator = SIMD2<Double>(ImmersiveMapProjection.wrapNormalizedWorldX(centerWorldMercator.x),
                                                 ImmersiveMapProjection.clampNormalizedWorldY(centerWorldMercator.y))
        self.zoom = zoom
        self.bearing = bearing
        self.pitch = pitch
    }

    init(cameraPosition: ImmersiveMapCameraPosition,
         cameraSettings: ImmersiveMapSettings.CameraSettings) {
        let maxLatitudeDeg = ImmersiveMapProjection.maxMercatorLatitude * (180.0 / .pi)
        let clampedLatitudeDegrees = min(max(cameraPosition.latitudeDegrees, -maxLatitudeDeg), maxLatitudeDeg)
        let latitudeRadians = (clampedLatitudeDegrees / 180.0) * Double.pi
        let longitudeRadians = (cameraPosition.longitudeDegrees / 180.0) * Double.pi
        let centerWorldMercator = ImmersiveMapProjection.worldMercator(latitude: latitudeRadians,
                                                              longitude: longitudeRadians)
        let clampedZoom = min(max(0, cameraPosition.zoom), cameraSettings.maximumZoom)
        self.init(centerWorldMercator: centerWorldMercator,
                  zoom: clampedZoom,
                  bearing: cameraPosition.bearing,
                  pitch: min(max(0, cameraPosition.pitch), cameraSettings.maximumReachablePitch(at: clampedZoom)))
    }

    func cameraPosition() -> ImmersiveMapCameraPosition {
        let latitudeRadians = ImmersiveMapProjection.latitude(fromNormalizedWorldY: centerWorldMercator.y)
        let longitudeRadians = ImmersiveMapProjection.longitude(fromNormalizedWorldX: centerWorldMercator.x)
        return ImmersiveMapCameraPosition(latitudeDegrees: latitudeRadians * (180.0 / .pi),
                                          longitudeDegrees: longitudeRadians * (180.0 / .pi),
                                          zoom: zoom,
                                          bearing: bearing,
                                          pitch: pitch)
    }
}
