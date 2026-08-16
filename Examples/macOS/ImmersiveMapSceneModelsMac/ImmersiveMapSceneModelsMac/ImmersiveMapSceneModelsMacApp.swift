// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapSceneModelsMacApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap 3D Scene Models") {
            SceneModelsScreen()
        }
        .defaultSize(width: 1100, height: 800)
    }
}

/// 3D scene models: USDZ assets anchored to geographic coordinates with the
/// `.sceneModels(...)` modifier. They render inside the map world pass with
/// real depth and the same light as extruded buildings, in flat mode, on the
/// globe, and through the morph.
///
/// Each demo city hosts its own cow, and the sliders always drive the cow of
/// the city the camera is over: fly or pan between Paris and Seoul and the
/// panel retargets itself. The sliders call the live transform API
/// (`setOrientation`, `setScale`, `setAltitude`), which eases over a duration
/// instead of snapping. The scale slider is logarithmic: at the top end the
/// cow is hundreds of kilometers tall and stays visible after zooming all the
/// way out to the globe.
private struct SceneModelsScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var sceneModels = ImmersiveMapSceneModelsController()
    @State private var city: DemoCity = .paris
    @State private var transforms: [DemoCity: ModelTransform] = [
        .paris: ModelTransform(heading: -35),
        .seoul: ModelTransform(heading: 30),
    ]
    @State private var isMissingAsset = false
    @State private var tapped: String?

    private static let scaleRange: ClosedRange<Double> = 0.25...10_000

    var body: some View {
        ZStack(alignment: .bottom) {
            ImmersiveMapView()
                .tileURLTemplate(hostedTileTemplate, headers: hostedTileHeaders())
                .camera(camera, position: DemoCity.paris.cameraPosition)
                .sceneModels(sceneModels)
                // Hit-testing follows the model through the morph and through
                // any animation: `coordinate` is where it was drawn.
                .onSceneModelTap { event in
                    tapped = String(format: "model %llu at %.4f°, %.4f°",
                                    event.model.id,
                                    event.coordinate.latitude,
                                    event.coordinate.longitude)
                }
                .enableCameraUIControls()
                .ignoresSafeArea()

            if let tapped {
                Label(tapped, systemImage: "hand.tap.fill")
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            controls
                .padding(20)
        }
        .task {
            let models = DemoSceneModels.makeModels()
            sceneModels.set(models)
            isMissingAsset = models.isEmpty
        }
        .onAppear {
            camera.onCameraPositionChanged = { position in
                // The engine can notify from inside SwiftUI's update pass, so
                // the subject switch is deferred to the next runloop turn.
                DispatchQueue.main.async {
                    let nearest = DemoCity.nearest(toLatitude: position.latitudeDegrees,
                                                   longitude: position.longitudeDegrees)
                    if nearest != city {
                        city = nearest
                    }
                }
            }
        }
        .onDisappear {
            camera.onCameraPositionChanged = nil
        }
        .alert("spot.usdz is missing from the app bundle", isPresented: $isMissingAsset) {
            Button("OK", role: .cancel) {}
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ForEach(DemoCity.allCases) { destination in
                    Button(destination.rawValue) {
                        camera.fly(to: destination.cameraPosition,
                                   options: CameraFlightOptions(duration: 3.0,
                                                                routeStyle: .greatCircle,
                                                                altitudeStyle: .overviewFirst))
                    }
                }

                Divider().frame(height: 20)

                // The subject follows the camera: whichever demo city is
                // closest owns the sliders below.
                Label("Cow in \(city.rawValue)", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
            }

            HStack(spacing: 18) {
                slider("Heading", value: binding(\.heading), range: -180...180) {
                    sceneModels.setOrientation(id: city.modelId,
                                               headingDegrees: transform.heading,
                                               duration: 0.4)
                }
                slider("Pitch", value: binding(\.pitch), range: -60...60) {
                    sceneModels.setOrientation(id: city.modelId,
                                               pitchDegrees: transform.pitch,
                                               duration: 0.4)
                }
                slider("Roll", value: binding(\.roll), range: -60...60) {
                    sceneModels.setOrientation(id: city.modelId,
                                               rollDegrees: transform.roll,
                                               duration: 0.4)
                }
                scaleSlider
                slider("Altitude, m", value: binding(\.altitude), range: 0...800) {
                    sceneModels.setAltitude(id: city.modelId,
                                            meters: transform.altitude,
                                            duration: 0.4)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        onChange: @escaping () -> Void) -> some View {
        VStack(spacing: 2) {
            Text("\(title): \(value.wrappedValue, specifier: "%.1f")")
                .font(.system(size: 11, design: .monospaced))
            Slider(value: value, in: range) { isEditing in
                if isEditing == false {
                    onChange()
                }
            }
            .frame(width: 130)
        }
    }

    /// Logarithmic: equal slider travel multiplies the scale by the same
    /// factor, so fine steps near ×1 and globe-sized values share one thumb.
    private var scaleSlider: some View {
        VStack(spacing: 2) {
            Text("Scale: ×\(scaleText)")
                .font(.system(size: 11, design: .monospaced))
            Slider(value: logScale,
                   in: log10(Self.scaleRange.lowerBound)...log10(Self.scaleRange.upperBound)) { isEditing in
                if isEditing == false {
                    sceneModels.setScale(id: city.modelId, transform.scale, duration: 0.4)
                }
            }
            .frame(width: 130)
        }
    }

    private var logScale: Binding<Double> {
        Binding(
            get: { log10(max(Self.scaleRange.lowerBound, transform.scale)) },
            set: { transforms[city, default: ModelTransform()].scale = pow(10, $0) }
        )
    }

    private var scaleText: String {
        let scale = transform.scale
        let format = scale < 10 ? "%.2f" : scale < 100 ? "%.1f" : "%.0f"
        return String(format: format, locale: .current, scale)
    }

    private var transform: ModelTransform {
        transforms[city, default: ModelTransform()]
    }

    private func binding(_ keyPath: WritableKeyPath<ModelTransform, Double>) -> Binding<Double> {
        Binding(
            get: { transforms[city, default: ModelTransform()][keyPath: keyPath] },
            set: { transforms[city, default: ModelTransform()][keyPath: keyPath] = $0 }
        )
    }
}

/// Slider state of one cow, kept per city so that switching the subject
/// restores what that cow was last set to.
private struct ModelTransform {
    var heading: Double = 0
    var pitch: Double = 0
    var roll: Double = 0
    var scale: Double = 1
    var altitude: Double = 0
}

/// The demo cities. Each owns one slider-addressable cow; the control panel
/// binds to whichever city the camera is currently closest to.
private enum DemoCity: String, CaseIterable, Identifiable {
    case paris = "Paris"
    case seoul = "Seoul"

    var id: String { rawValue }

    var modelId: UInt64 {
        switch self {
        case .paris: return DemoSceneModels.spotByTheEiffelTower
        case .seoul: return DemoSceneModels.spotInSeoul
        }
    }

    var coordinate: GeoCoordinate {
        switch self {
        case .paris: return DemoSceneModels.paris
        case .seoul: return DemoSceneModels.seoul
        }
    }

    var cameraPosition: ImmersiveMapCameraPosition {
        switch self {
        case .paris:
            return ImmersiveMapCameraPosition(latitudeDegrees: coordinate.latitude,
                                              longitudeDegrees: coordinate.longitude,
                                              zoom: 15.6,
                                              bearing: 0.4,
                                              pitch: 1.0)
        case .seoul:
            return ImmersiveMapCameraPosition(latitudeDegrees: coordinate.latitude,
                                              longitudeDegrees: coordinate.longitude,
                                              zoom: 15.4,
                                              bearing: 0.2,
                                              pitch: 0.95)
        }
    }

    /// Closest demo city to a camera position, on a longitude-wrapped
    /// flat-earth metric: plenty for two cities half a world apart.
    static func nearest(toLatitude latitude: Double, longitude: Double) -> DemoCity {
        func squaredDistance(to city: DemoCity) -> Double {
            let deltaLatitude = city.coordinate.latitude - latitude
            let wrappedDeltaLongitude = (city.coordinate.longitude - longitude + 540)
                .truncatingRemainder(dividingBy: 360) - 180
            let scaledDeltaLongitude = wrappedDeltaLongitude * cos(latitude * .pi / 180)
            return deltaLatitude * deltaLatitude + scaledDeltaLongitude * scaledDeltaLongitude
        }
        return allCases.min { squaredDistance(to: $0) < squaredDistance(to: $1) } ?? .paris
    }
}

/// The hosted tile endpoint, written as the one-line URL template. The API key
/// is read from the local environment (`IMMERSIVEMAP_API_KEY`) so it stays on
/// this machine and never lands in the repository; without it the map renders
/// on the shared anonymous pool.
private let hostedTileTemplate = "https://tiles.immersivemap.dev/{z}/{x}/{y}.mvt"

private func hostedTileHeaders() -> [String: String] {
    guard let key = ProcessInfo.processInfo.environment["IMMERSIVEMAP_API_KEY"],
          key.isEmpty == false else {
        return [:]
    }
    return ["Authorization": "Bearer \(key)"]
}
