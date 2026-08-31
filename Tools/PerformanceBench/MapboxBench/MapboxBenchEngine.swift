// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreLocation
import MapboxMaps
import SwiftUI
import UIKit

/// The variants this binary carries. The access token must be set before
/// any Mapbox object exists, and a cold cache is an SDK-level clear, so
/// both live in `prepare`, ahead of the memory baseline.
@MainActor
final class MapboxEngineCatalog: BenchEngineCatalog {
    let defaultEngineName = "mapbox-standard"

    func prepare(engineName: String, coldCache: Bool) async -> Bool {
        guard let token = BenchSecrets.mapboxAccessToken() else {
            print("BENCH_ERROR no MAPBOX_ACCESS_TOKEN in the environment or LocalSecrets.plist")
            return false
        }
        MapboxOptions.accessToken = token
        if coldCache {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                MapboxMap.clearData { _ in continuation.resume() }
            }
        }
        return true
    }

    func makeEngine(named name: String, targetFPS: Int, coldCache: Bool) -> BenchEngine? {
        switch name {
        case "mapbox-standard":
            return MapboxBenchEngine(targetFPS: targetFPS, style: .standard, styleName: "standard")
        case "mapbox-standard-msaa4":
            return MapboxBenchEngine(targetFPS: targetFPS, style: .standard, styleName: "standard", sampleCount: 4)
        case "mapbox-streets":
            return MapboxBenchEngine(targetFPS: targetFPS, style: .streets, styleName: "streets")
        default:
            return nil
        }
    }
}

@MainActor
final class MapboxBenchEngine: BenchEngine {
    let name: String
    let version: String
    let view: UIView
    var onFrame: (() -> Void)?

    private let mapView: MapView
    private var tokens: [AnyCancelable] = []

    init(targetFPS: Int, style: StyleURI, styleName: String, sampleCount: Int = 1) {
        name = "mapbox-\(styleName)" + (sampleCount > 1 ? "-msaa\(sampleCount)" : "")
        version = MapboxBenchEngine.sdkVersion()
        let camera = CameraOptions(center: CLLocationCoordinate2D(latitude: BenchScenario.establish.latitude,
                                                                  longitude: BenchScenario.establish.longitude),
                                   zoom: BenchScenario.establish.zoom,
                                   bearing: 0,
                                   pitch: 0)
        let options = MapInitOptions(cameraOptions: camera, styleURI: style, antialiasingSampleCount: sampleCount)
        mapView = MapView(frame: .zero, mapInitOptions: options)
        mapView.preferredFrameRateRange = CAFrameRateRange(minimum: Float(targetFPS),
                                                           maximum: Float(targetFPS),
                                                           preferred: Float(targetFPS))
        view = mapView
        tokens.append(mapView.mapboxMap.onRenderFrameFinished.observe { [weak self] _ in
            self?.onFrame?()
        })
    }

    func jump(to pose: BenchPose) {
        mapView.mapboxMap.setCamera(to: Self.options(pose))
    }

    func fly(to pose: BenchPose, duration: TimeInterval, completion: @escaping () -> Void) {
        _ = mapView.camera.fly(to: Self.options(pose), duration: duration) { _ in
            completion()
        }
    }

    private static func options(_ pose: BenchPose) -> CameraOptions {
        CameraOptions(center: CLLocationCoordinate2D(latitude: pose.latitude, longitude: pose.longitude),
                      zoom: pose.zoom,
                      bearing: pose.bearing,
                      pitch: pose.pitch)
    }

    /// MapboxMaps is a source package linked into the app, so its bundle is
    /// the app's; the version is the exact requirement the project pins.
    private static func sdkVersion() -> String {
        "11.26.0"
    }
}
