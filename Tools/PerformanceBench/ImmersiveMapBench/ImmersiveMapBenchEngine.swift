// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMap
import SwiftUI
import UIKit

/// The variants this binary carries. ImmersiveMap needs no SDK-level setup
/// before the baseline: credentials travel as request headers, and a cold
/// cache is the engine's own `clearDiskCachesOnLaunch`.
@MainActor
final class ImmersiveMapEngineCatalog: BenchEngineCatalog {
    let defaultEngineName = "immersivemap"

    func prepare(engineName: String, coldCache: Bool) async -> Bool {
        true
    }

    func makeEngine(named name: String, targetFPS: Int, coldCache: Bool) -> BenchEngine? {
        guard let variant = ImmersiveMapBenchEngine.Variant(rawValue: name) else {
            return nil
        }
        return ImmersiveMapBenchEngine(targetFPS: targetFPS, coldCache: coldCache, variant: variant)
    }
}

@MainActor
final class ImmersiveMapBenchEngine: BenchEngine {
    /// Feature switches for A/B runs against the default configuration.
    enum Variant: String {
        /// Everything at its default.
        case standard = "immersivemap"
        /// Cascade shadows off.
        case noShadows = "immersivemap-noshadows"
        /// Shadows off: the cheapest flat frame the public settings allow
        /// without changing what is drawn.
        case lean = "immersivemap-lean"
        /// Transparent space: the space background and the stars are not
        /// drawn at all, which isolates the sky's share of a globe frame in
        /// an A/B against the default.
        case noSky = "immersivemap-nosky"
        /// Kept for measurement continuity: with no space décor but the
        /// stars, the planet alone is exactly transparent space, the same
        /// frame as `noSky`.
        case bare = "immersivemap-bare"
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
        // BENCH_CONTINUOUS=1 keeps the display link running for the whole
        // run, the control for the on-demand loop's behaviour on a
        // programmatic pan: the engine keeps the link awake for 100 ms after
        // every jump that changes the position, and this run shows what the
        // pan looks like with no pause at all.
        let continuous = ProcessInfo.processInfo.environment["BENCH_CONTINUOUS"] == "1"
        let renderLoop = ImmersiveMapSettings.RenderLoopSettings(forceContinuousRendering: continuous,
                                                                 interactionFramesPerSecond: targetFPS,
                                                                 labelFadeFramesPerSecond: 30)
        var map = ImmersiveMapView()
            .tileURLTemplate(BenchSecrets.immersiveMapTileTemplate, headers: BenchSecrets.immersiveMapHeaders())
            .camera(camera)
            .renderLoopSettings(renderLoop)
            .tileSettings(clearDiskCachesOnLaunch: coldCache)
            .viewReuse(false)
        // BENCH_ROOFS=1 turns the shaped building roofs on (they are off by
        // default), for A/B measurements of the roof geometry cost.
        if ProcessInfo.processInfo.environment["BENCH_ROOFS"] == "1" {
            map = map.buildingRoofShapes()
        }
        switch variant {
        case .standard:
            break
        case .noShadows:
            map = map.shadows(isEnabled: false)
        case .lean:
            map = map.shadows(isEnabled: false)
        case .noSky:
            map = map.transparentSpace()
        case .bare:
            map = map.transparentSpace()
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
