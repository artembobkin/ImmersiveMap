// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  ImmersiveMapCameraPosition.swift
//  ImmersiveMap
//

import Foundation

public struct ImmersiveMapCameraPosition: Equatable, Sendable {
    public static let `default` = ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                                             longitudeDegrees: 0,
                                                             zoom: 0,
                                                             bearing: 0,
                                                             pitch: 0)

    public let latitudeDegrees: Double
    public let longitudeDegrees: Double
    public let zoom: Double
    public let bearing: Float
    public let pitch: Float

    public init(latitudeDegrees: Double,
                longitudeDegrees: Double,
                zoom: Double,
                bearing: Float = 0,
                pitch: Float = 0) {
        self.latitudeDegrees = latitudeDegrees
        self.longitudeDegrees = longitudeDegrees
        self.zoom = zoom
        self.bearing = bearing
        self.pitch = pitch
    }
}

public enum CameraFlightRouteStyle: Sendable, Equatable {
    case automatic
    case mercatorShortestPath
    case greatCircle
}

public enum CameraFlightAltitudeStyle: Sendable, Equatable {
    case direct
    case overviewFirst
}

public struct CameraFlightOptions: Sendable, Equatable {
    public static let `default` = CameraFlightOptions(duration: 1.35,
                                                      routeStyle: .automatic,
                                                      altitudeStyle: .direct)
    private static let defaultDuration: TimeInterval = 1.35

    public let duration: TimeInterval
    public let routeStyle: CameraFlightRouteStyle
    public let altitudeStyle: CameraFlightAltitudeStyle

    public init(duration: TimeInterval,
                routeStyle: CameraFlightRouteStyle = .automatic,
                altitudeStyle: CameraFlightAltitudeStyle = .direct) {
        let fallbackDuration = Self.defaultDuration
        let sanitizedDuration = duration.isFinite ? duration : fallbackDuration
        self.duration = max(0, sanitizedDuration)
        self.routeStyle = routeStyle
        self.altitudeStyle = altitudeStyle
    }
}
