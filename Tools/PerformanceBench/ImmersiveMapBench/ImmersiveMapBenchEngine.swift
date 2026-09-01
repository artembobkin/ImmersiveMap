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
        /// Shadows and the atmosphere halo off: the cheapest frame the
        /// public settings allow without changing what is drawn.
        case lean = "immersivemap-lean"
        /// Transparent space: the space background, the stars, the Sun and
        /// the atmosphere halo are not drawn at all, which isolates the
        /// sky's share of a globe frame in an A/B against the default.
        case noSky = "immersivemap-nosky"
        /// The planet alone: transparent space plus the atmosphere and the
        /// earth scene off, so the globe surface draws with no starfield,
        /// no halo, no surface glow and no day/night terminator. The floor
        /// the public settings allow for a globe frame.
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
        case .noSky:
            map = map.transparentSpace()
        case .bare:
            map = map.transparentSpace().atmosphere(isEnabled: false).earthScene(isEnabled: false)
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
