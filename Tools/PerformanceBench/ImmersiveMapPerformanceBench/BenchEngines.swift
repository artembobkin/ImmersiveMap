// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreLocation
import ImmersiveMap
import MapboxMaps
import SwiftUI
import UIKit

/// What the harness needs from a map engine: a view to put on screen, an
/// instant camera set, an animated flight, and a per-frame callback.
@MainActor
protocol BenchEngine: AnyObject {
    var name: String { get }
    var version: String { get }
    var view: UIView { get }
    var onFrame: (() -> Void)? { get set }
    func jump(to pose: BenchPose)
    func fly(to pose: BenchPose, duration: TimeInterval, completion: @escaping () -> Void)
}

// MARK: - ImmersiveMap

@MainActor
final class ImmersiveMapBenchEngine: BenchEngine {
    /// Feature switches for A/B runs against the default configuration.
    enum Variant: String {
        /// Everything at its default.
        case standard = "immersivemap"
        /// Cascade shadows off.
        case noShadows = "immersivemap-noshadows"
        /// Shadows and the atmosphere halo off: the cheapest frame the
        /// public settings allow without changing what is drawn.
        case lean = "immersivemap-lean"
    }

    let name: String
    let version: String
    let view: UIView
    var onFrame: (() -> Void)?

    private let camera = ImmersiveMapCameraController()
    private let host: UIHostingController<AnyView>

    init(targetFPS: Int, coldCache: Bool, variant: Variant = .standard) {
        name = variant.rawValue
        version = ImmersiveMapBenchEngine.packageVersion()
        let renderLoop = ImmersiveMapSettings.RenderLoopSettings(forceContinuousRendering: false,
                                                                 interactionFramesPerSecond: targetFPS,
                                                                 labelFadeFramesPerSecond: 30)
        var map = ImmersiveMapView()
            .tileURLTemplate(BenchSecrets.immersiveMapTileTemplate, headers: BenchSecrets.immersiveMapHeaders())
            .camera(camera)
            .renderLoopSettings(renderLoop)
            .tileSettings(clearDiskCachesOnLaunch: coldCache)
            .viewReuse(false)
        switch variant {
        case .standard:
            break
        case .noShadows:
            map = map.shadows(isEnabled: false)
        case .lean:
            map = map.shadows(isEnabled: false).atmosphere(isEnabled: false)
        }
        let rootView = map.ignoresSafeArea()
        host = UIHostingController(rootView: AnyView(rootView))
        host.view.backgroundColor = .black
        view = host.view
        // The camera position callback fires on every frame the camera moves,
        // which is every frame of a flight or a pan: the closest thing to a
        // frame callback the public API has.
        camera.onCameraPositionChanged = { [weak self] _ in
            Task { @MainActor in self?.onFrame?() }
        }
    }

    func jump(to pose: BenchPose) {
        camera.jump(to: Self.position(pose))
    }

    func fly(to pose: BenchPose, duration: TimeInterval, completion: @escaping () -> Void) {
        let options = CameraFlightOptions(duration: duration, routeStyle: .automatic, altitudeStyle: .overviewFirst)
        camera.fly(to: Self.position(pose), options: options) { _ in
            Task { @MainActor in completion() }
        }
    }

    private static func position(_ pose: BenchPose) -> ImmersiveMapCameraPosition {
        ImmersiveMapCameraPosition(latitudeDegrees: pose.latitude,
                                   longitudeDegrees: pose.longitude,
                                   zoom: pose.zoom,
                                   bearing: Float(pose.bearing * .pi / 180),
                                   pitch: Float(pose.pitch * .pi / 180))
    }

    private static func packageVersion() -> String {
        // The changelog's top version is the package version; on a device the
        // checkout is out of reach, so fall back to the git description the
        // build phase can bake in later. "checkout" says it ran from source.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let changelog = directory.appendingPathComponent("CHANGELOG.md")
            if let text = try? String(contentsOf: changelog, encoding: .utf8) {
                for line in text.split(separator: "\n") where line.hasPrefix("## [") && line.contains("Unreleased") == false {
                    if let close = line.firstIndex(of: "]") {
                        return String(line[line.index(line.startIndex, offsetBy: 4)..<close])
                    }
                }
                break
            }
            directory = directory.deletingLastPathComponent()
        }
        return "checkout"
    }
}

// MARK: - Mapbox

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
