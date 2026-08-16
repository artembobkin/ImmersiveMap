// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapRoutesMacApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap Routes") {
            RoutesScreen()
        }
        .defaultSize(width: 1100, height: 800)
    }
}

/// A round-the-world journey drawn leg by leg: a dashed plan, a solid line that
/// grows along it, a biplane flying the same trajectory, and a camera that
/// travels with them.
///
/// The three pieces stay in step because they share one `ImmersiveMapGeoPath`
/// and one duration; nothing passes between them at runtime.
private struct RoutesScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var routes = ImmersiveMapRoutesController()
    @State private var sceneModels = ImmersiveMapSceneModelsController()
    @State private var isFlying = false
    @State private var activeLegTitle: String?
    @State private var missingModel = false
    @State private var tappedPosition: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            ImmersiveMapView()
                .tileURLTemplate(hostedTileTemplate, headers: hostedTileHeaders())
                .camera(camera, position: FlightStoryboard.overview)
                .routes(routes)
                .sceneModels(sceneModels)
                // The plane is tappable while it flies: `coordinate` is where it
                // is right now, whereas `model.coordinate` is already the leg's
                // destination.
                .onSceneModelTap { event in
                    tappedPosition = String(format: "%.1f°, %.1f°",
                                            event.coordinate.latitude,
                                            event.coordinate.longitude)
                }
                .ignoresSafeArea()

            controls
                .padding(20)

            VStack(alignment: .leading, spacing: 8) {
                if let activeLegTitle {
                    Text(activeLegTitle)
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                if let tappedPosition {
                    Label("Plane at \(tappedPosition)", systemImage: "hand.tap.fill")
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .alert("biplane.obj is missing from the app bundle",
               isPresented: $missingModel) {
            Button("OK", role: .cancel) {}
        }
    }

    private var controls: some View {
        Button {
            if isFlying {
                stopJourney()
            } else {
                startJourney()
            }
        } label: {
            Label(isFlying ? "Stop" : "Fly the journey",
                  systemImage: isFlying ? "stop.circle.fill" : "airplane.circle.fill")
                .padding(.horizontal, 6)
        }
        .controlSize(.large)
        .keyboardShortcut(.space, modifiers: [])
    }

    // MARK: - Journey

    private func startJourney() {
        guard let source = FlightStoryboard.planeSource() else {
            missingModel = true
            return
        }
        guard let first = FlightStoryboard.legs.first else { return }

        isFlying = true
        tappedPosition = nil
        routes.clear()
        sceneModels.clear()
        sceneModels.add(ImmersiveMapSceneModel(
            id: FlightStoryboard.planeModelId,
            source: source,
            coordinate: first.from,
            fitDiameterMeters: FlightStoryboard.planeDiameterMeters))

        // Routes are drawn on the globe, so the camera pulls back to an
        // overview before the first leg starts.
        camera.fly(to: FlightStoryboard.overview,
                   options: CameraFlightOptions(duration: 1.8)) { _ in
            flyLeg(index: 0)
        }
    }

    private func flyLeg(index: Int) {
        guard isFlying, index < FlightStoryboard.legs.count else {
            isFlying = false
            activeLegTitle = nil
            return
        }

        let leg = FlightStoryboard.legs[index]
        activeLegTitle = leg.title

        // The whole leg, dashed, underneath the solid line that grows along it.
        routes.add(ImmersiveMapRoute(id: FlightStoryboard.plannedRouteId(for: index),
                                     path: leg.path,
                                     color: FlightStoryboard.plannedColor,
                                     widthPoints: FlightStoryboard.plannedWidthPoints,
                                     dash: FlightStoryboard.plannedDash))
        routes.add(ImmersiveMapRoute(id: FlightStoryboard.flownRouteId(for: index),
                                     path: leg.path,
                                     color: leg.color,
                                     widthPoints: FlightStoryboard.flownWidthPoints,
                                     progress: 0))

        // One path, one duration, one curve: the line, the plane and the camera
        // all resolve the same point of the leg on every frame.
        routes.setProgress(id: FlightStoryboard.flownRouteId(for: index), 1, duration: leg.seconds)
        camera.follow(path: leg.path,
                      duration: leg.seconds,
                      options: FlightStoryboard.cameraFollow)
        sceneModels.animate(id: FlightStoryboard.planeModelId,
                            along: leg.path,
                            duration: leg.seconds) { finished in
            // false means the animation was cancelled or superseded, so the
            // journey must not continue on its own.
            guard finished else { return }
            flyLeg(index: index + 1)
        }
    }

    private func stopJourney() {
        isFlying = false
        activeLegTitle = nil
        sceneModels.cancelPathAnimation(id: FlightStoryboard.planeModelId)
        camera.cancelFollow()
        routes.clear()
        sceneModels.clear()
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
