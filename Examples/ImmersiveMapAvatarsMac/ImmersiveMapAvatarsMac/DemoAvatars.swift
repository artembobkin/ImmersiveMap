// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// Avatar markers with random portraits (pravatar.cc): a crowd on the streets of
/// Tokyo and Dubai, plus a few points around the world that are visible on the
/// globe. Until a portrait loads, the numbered `AvatarMarkerImageFactory`
/// placeholder is shown.
enum DemoAvatars {
    /// The Tokyo crowd, dense enough to show the collision layout and to have
    /// something worth merging.
    static let tokyo = GeoCoordinate(latitude: 35.6595, longitude: 139.7005)
    static let dubai = GeoCoordinate(latitude: 25.1972, longitude: 55.2744)

    static let tokyoIDs: [UInt64] = Array(1...8)
    static let dubaiIDs: [UInt64] = Array(9...16)
    static let worldIDs: [UInt64] = Array(17...20)

    static func makeMarkers() -> [AvatarMarker] {
        var markers: [AvatarMarker] = []
        var nextID: UInt64 = 1

        func add(lat: Double,
                 lon: Double,
                 image: Int,
                 battery: Int? = nil,
                 speed: Int? = nil) {
            markers.append(AvatarMarker(id: nextID,
                                        latitude: lat,
                                        longitude: lon,
                                        imageURL: URL(string: "https://i.pravatar.cc/256?img=\(image)")!,
                                        placeholder: AvatarMarkerImageFactory.number(Int(nextID)),
                                        batteryPercent: battery,
                                        speedKilometersPerHour: speed))
            nextID += 1
        }

        // Crowd around the streets of Tokyo (ids 1...8).
        add(lat: tokyo.latitude + 0.0012, lon: tokyo.longitude + 0.0018, image: 11, battery: 84)
        add(lat: tokyo.latitude - 0.0016, lon: tokyo.longitude + 0.0009, image: 12, speed: 14)
        add(lat: tokyo.latitude + 0.0007, lon: tokyo.longitude - 0.0021, image: 13, battery: 47)
        add(lat: tokyo.latitude - 0.0011, lon: tokyo.longitude - 0.0013, image: 14)
        add(lat: tokyo.latitude + 0.0024, lon: tokyo.longitude - 0.0004, image: 15, battery: 92, speed: 5)
        add(lat: tokyo.latitude - 0.0025, lon: tokyo.longitude + 0.0022, image: 16)
        add(lat: tokyo.latitude + 0.0003, lon: tokyo.longitude + 0.0032, image: 17, battery: 61)
        add(lat: tokyo.latitude - 0.0005, lon: tokyo.longitude - 0.0034, image: 18, speed: 32)

        // Crowd around Dubai (ids 9...16).
        add(lat: dubai.latitude + 0.0014, lon: dubai.longitude + 0.0011, image: 21, battery: 73)
        add(lat: dubai.latitude - 0.0009, lon: dubai.longitude + 0.0024, image: 22)
        add(lat: dubai.latitude + 0.0021, lon: dubai.longitude - 0.0008, image: 23, speed: 41)
        add(lat: dubai.latitude - 0.0019, lon: dubai.longitude - 0.0017, image: 24, battery: 28)
        add(lat: dubai.latitude + 0.0006, lon: dubai.longitude - 0.0029, image: 25)
        add(lat: dubai.latitude - 0.0002, lon: dubai.longitude + 0.0035, image: 26, battery: 55, speed: 9)
        add(lat: dubai.latitude + 0.0028, lon: dubai.longitude + 0.0002, image: 27)
        add(lat: dubai.latitude - 0.0027, lon: dubai.longitude - 0.0003, image: 28, speed: 23)

        // Around the world (ids 17...20): visible on the globe overview.
        add(lat: 55.7558, lon: 37.6173, image: 31, battery: 66)    // Moscow
        add(lat: -22.9068, lon: -43.1729, image: 34, speed: 17)    // Rio
        add(lat: 37.7749, lon: -122.4194, image: 35, battery: 39)  // San Francisco
        add(lat: 19.4326, lon: -99.1332, image: 36)                // Mexico City

        return markers
    }
}
