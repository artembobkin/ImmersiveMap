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

/// 3D scene models: USDZ and OBJ assets anchored to geographic coordinates with
/// the `.sceneModels(...)` modifier. They render inside the map world pass with
/// real depth and the same light as extruded buildings, in flat mode, on the
/// globe, and through the morph.
///
/// The sliders drive the live transform API (`setOrientation`, `setScale`,
/// `setAltitude`), which eases over a duration instead of snapping.
private struct SceneModelsScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var sceneModels = ImmersiveMapSceneModelsController()
    @State private var heading: Double = -35
    @State private var pitch: Double = 0
    @State private var roll: Double = 0
    @State private var scale: Double = 1
    @State private var altitude: Double = 0
    @State private var isMissingAsset = false
    @State private var tapped: String?

    /// The model the sliders address. The other three stay put as a reference.
    private let subject = DemoSceneModels.spotByTheEiffelTower

    var body: some View {
        ZStack(alignment: .bottom) {
            ImmersiveMapView()
                .camera(camera, position: Self.paris)
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
            isMissingAsset = models.contains { $0.id == DemoSceneModels.spotByTheEiffelTower } == false
        }
        .alert("spot.usdz is missing from the app bundle", isPresented: $isMissingAsset) {
            Button("OK", role: .cancel) {}
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button("Paris") {
                    camera.fly(to: Self.paris, options: CameraFlightOptions(duration: 2.0))
                }
                Button("Tokyo") {
                    camera.fly(to: Self.tokyo,
                               options: CameraFlightOptions(duration: 3.0,
                                                            routeStyle: .greatCircle,
                                                            altitudeStyle: .overviewFirst))
                }
                Button("Dubai") {
                    camera.fly(to: Self.dubai,
                               options: CameraFlightOptions(duration: 3.0,
                                                            routeStyle: .greatCircle,
                                                            altitudeStyle: .overviewFirst))
                }

                Divider().frame(height: 20)

                // `move` glides along a great circle with a duration derived
                // from the distance, the same feel as avatar movement.
                Button("Send the cow to Tokyo") {
                    sceneModels.move(id: subject, to: DemoSceneModels.tokyo)
                }
                Button("Bring her back") {
                    sceneModels.move(id: subject, to: DemoSceneModels.paris)
                }
            }

            HStack(spacing: 18) {
                slider("Heading", value: $heading, range: -180...180) {
                    sceneModels.setOrientation(id: subject,
                                               headingDegrees: heading,
                                               duration: 0.4)
                }
                slider("Pitch", value: $pitch, range: -60...60) {
                    sceneModels.setOrientation(id: subject,
                                               pitchDegrees: pitch,
                                               duration: 0.4)
                }
                slider("Roll", value: $roll, range: -60...60) {
                    sceneModels.setOrientation(id: subject,
                                               rollDegrees: roll,
                                               duration: 0.4)
                }
                slider("Scale", value: $scale, range: 0.25...4) {
                    sceneModels.setScale(id: subject, scale, duration: 0.4)
                }
                slider("Altitude, m", value: $altitude, range: 0...800) {
                    sceneModels.setAltitude(id: subject, meters: altitude, duration: 0.4)
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

    private static let paris = ImmersiveMapCameraPosition(
        latitudeDegrees: 48.8570,
        longitudeDegrees: 2.2952,
        zoom: 15.6,
        bearing: 0.4,
        pitch: 1.0
    )

    private static let tokyo = ImmersiveMapCameraPosition(
        latitudeDegrees: 35.6595,
        longitudeDegrees: 139.7005,
        zoom: 15.4,
        bearing: 0.2,
        pitch: 0.95
    )

    private static let dubai = ImmersiveMapCameraPosition(
        latitudeDegrees: 25.1972,
        longitudeDegrees: 55.2744,
        zoom: 14.8,
        bearing: -0.3,
        pitch: 0.95
    )
}
