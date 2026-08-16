// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapAvatarsMacApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap Avatars") {
            AvatarsScreen()
        }
        .defaultSize(width: 1100, height: 800)
    }
}

/// Avatar markers: the GPU-atlas path for large numbers of uniform, image-based
/// markers, owned by an `ImmersiveMapAvatarsController`. Unlike SwiftUI markers
/// they collide and lay themselves out, they merge into clusters, and `move`
/// glides them along a great circle instead of snapping.
///
/// Tapping is here too. `ImmersiveMapSelectionController` covers avatars and
/// 3D scene models (`ImmersiveMapSelection.Kind`), and this app has avatars, so
/// it is where the avatar half is shown; the model half lives in
/// `ImmersiveMapSceneModelsMac`.
private struct AvatarsScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var avatars = ImmersiveMapAvatarsController()
    @State private var selection = ImmersiveMapSelectionController()
    @State private var isTokyoMerged = false
    @State private var isWalking = false
    @State private var lastEvent = "Tap an avatar"
    @State private var selectedID: UInt64?
    @State private var walkPhase: Double = 0
    @State private var walkTimer: Timer?

    private static let mergedTokyoID: UInt64 = 100

    var body: some View {
        ZStack(alignment: .bottom) {
            ImmersiveMapView()
                .tileURLTemplate(hostedTileTemplate, headers: hostedTileHeaders())
                .camera(camera, position: Self.tokyoStreet)
                .avatars(avatars)
                .avatarSettings(size: .px128)
                .selection(selection)
                .onAvatarTap { event in
                    lastEvent = "tap: marker \(event.marker.id) at "
                        + "\(Int(event.screenPoint.x)), \(Int(event.screenPoint.y))"
                }
                .enableCameraUIControls()
                .ignoresSafeArea()

            VStack(spacing: 10) {
                Text(statusLine)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())

                controls
            }
            .padding(20)
        }
        .task {
            avatars.set(DemoAvatars.makeMarkers())
            // The selection controller mirrors what a tap did, and can drive the
            // same state from code. Both callbacks fire on the main thread.
            selection.onSelectionChanged = { event in
                selectedID = event.selection.objectID
                lastEvent = "selected \(event.selection.kind.rawValue) "
                    + "\(event.selection.objectID) via \(event.source.rawValue)"
            }
            selection.onSelectionCleared = { event in
                selectedID = nil
                lastEvent = "cleared \(event.previousSelection.objectID) via \(event.source.rawValue)"
            }
            selection.onMapBackgroundTap = { _ in
                lastEvent = "tapped the map background"
            }
        }
        .onDisappear {
            walkTimer?.invalidate()
        }
    }

    private var statusLine: String {
        let selected = selectedID.map { "#\($0)" } ?? "none"
        return "selection: \(selected)   |   \(lastEvent)"
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("Fly to Tokyo") {
                camera.fly(to: Self.tokyoStreet, options: CameraFlightOptions(duration: 1.6))
            }
            Button("Fly to the globe") {
                camera.fly(to: Self.overview,
                           options: CameraFlightOptions(duration: 2.4,
                                                        routeStyle: .greatCircle,
                                                        altitudeStyle: .overviewFirst))
            }

            Divider().frame(height: 20)

            // A merged marker draws in place of its members: its coordinate is
            // their live average, its image cycles through them, and a count
            // badge shows how many are inside.
            Button(isTokyoMerged ? "Unmerge Tokyo" : "Merge Tokyo") {
                toggleMerge()
            }

            // `move` animates by itself: the duration scales with the distance,
            // so a live track only has to push new coordinates.
            Toggle("Walk the crowd", isOn: $isWalking)
                .toggleStyle(.switch)
                .onChange(of: isWalking) { _, newValue in
                    newValue ? startWalking() : stopWalking()
                }

            Divider().frame(height: 20)

            Button("Select #1") {
                selection.select(ImmersiveMapSelection(kind: .avatar, objectID: 1))
            }
            Button("Clear") {
                selection.clearSelection()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func toggleMerge() {
        if isTokyoMerged {
            avatars.unmerge(mergedID: Self.mergedTokyoID)
        } else {
            avatars.merge(ids: DemoAvatars.tokyoIDs,
                          mergedID: Self.mergedTokyoID,
                          imageCycleInterval: 1.5)
        }
        isTokyoMerged.toggle()
    }

    private func startWalking() {
        walkTimer?.invalidate()
        walkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                stepWalk()
            }
        }
    }

    private func stopWalking() {
        walkTimer?.invalidate()
        walkTimer = nil
    }

    /// Members of a merged group stay addressable while hidden, so the merged
    /// marker glides as its members walk.
    private func stepWalk() {
        walkPhase += 0.35
        for (index, id) in DemoAvatars.tokyoIDs.enumerated() {
            let angle = walkPhase + Double(index) * (2 * .pi / Double(DemoAvatars.tokyoIDs.count))
            avatars.move(id: id,
                         latitude: DemoAvatars.tokyo.latitude + 0.0022 * sin(angle),
                         longitude: DemoAvatars.tokyo.longitude + 0.0028 * cos(angle))
        }
    }

    private static let tokyoStreet = ImmersiveMapCameraPosition(
        latitudeDegrees: 35.6595,
        longitudeDegrees: 139.7005,
        zoom: 16.2,
        bearing: 0.3,
        pitch: 0.9
    )

    private static let overview = ImmersiveMapCameraPosition(
        latitudeDegrees: 25,
        longitudeDegrees: 60,
        zoom: 1.7,
        bearing: 0,
        pitch: 0.08
    )
}

/// The hosted tile endpoint, written as the one-line URL template. The API key
/// comes from `IMMERSIVEMAP_API_KEY` in the environment or from the gitignored
/// `LocalSecrets.plist` at the repository root, so a real key never has to be
/// typed into a committed scheme; without a key the map renders on the shared
/// anonymous pool.
private let hostedTileTemplate = "https://immersivemap.dev/tiles/{z}/{x}/{y}.mvt"

private func hostedTileHeaders() -> [String: String] {
    guard let key = localAPIKey(), key.isEmpty == false else {
        return [:]
    }
    return ["Authorization": "Bearer \(key)"]
}

/// The environment wins (the scheme carries an empty placeholder for it);
/// otherwise the key comes from the gitignored `LocalSecrets.plist` at the
/// repository root, found from this source file's path, which exists wherever
/// the app can also read it: on the Mac and in the simulator. A physical
/// device sees neither and uses the scheme variable.
private func localAPIKey() -> String? {
    if let key = ProcessInfo.processInfo.environment["IMMERSIVEMAP_API_KEY"],
       key.isEmpty == false {
        return key
    }
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
            let secrets = directory.appendingPathComponent("LocalSecrets.plist")
            return NSDictionary(contentsOf: secrets)?["IMMERSIVEMAP_API_KEY"] as? String
        }
        directory = directory.deletingLastPathComponent()
    }
    return nil
}
