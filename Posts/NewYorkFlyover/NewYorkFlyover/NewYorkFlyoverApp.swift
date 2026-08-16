// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImmersiveMap

@main
struct NewYorkFlyoverApp: App {
    var body: some Scene {
        WindowGroup("New York Flyover") {
            FlyoverScreen()
        }
        .defaultSize(width: 1100, height: 800)
    }
}

/// Output formats for the rendered post, all 60 fps HEVC.
private enum VideoFormat: String, CaseIterable, Identifiable {
    case widescreen1080p = "1080p"
    case widescreen4K = "4K"
    case vertical = "9:16"

    var id: String { rawValue }

    var configuration: ImmersiveMapVideoExportConfiguration {
        switch self {
        case .widescreen1080p:
            return ImmersiveMapVideoExportConfiguration(width: 1920, height: 1080)
        case .widescreen4K:
            return ImmersiveMapVideoExportConfiguration(width: 3840, height: 2160)
        case .vertical:
            return ImmersiveMapVideoExportConfiguration(width: 1080, height: 1920)
        }
    }
}

/// The New York post scene: `NewYorkStoryboard` plays as a looped on-screen
/// preview (started with the button or the R key, stopped with R again, Esc,
/// or any gesture on the map), and "Render Video" writes one lap of the same
/// storyboard to a QuickTime file offline while the on-screen map stays fully
/// interactive.
private struct FlyoverScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var tour: ImmersiveMapCameraTourController?
    @State private var videoRecorder = ImmersiveMapTourVideoRecorder()
    @State private var videoFormat: VideoFormat = .widescreen4K
    @State private var isTourRunning = false
    @State private var isRenderingVideo = false
    @State private var renderFraction: Double = 0
    @State private var showChrome = true

    private var cinematicLabelSettings: ImmersiveMapSettings.LabelSettings {
        var labels = ImmersiveMapSettings.default.labels
        labels.houseNumbers.enabled = false
        return labels
    }

    /// The default style minus POI badges: their colored icons read as app
    /// chrome in footage meant to look like a flight, not a map screen.
    private var cinematicMapStyle: ImmersiveMapTilesMapStyle {
        ImmersiveMapTilesMapStyle(configuration: .immersiveMapTilesDefault.labelVisibility { visibility in
            visibility.poiMinimumZoom = 30
        })
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ImmersiveMapView()
                .tileURLTemplate(hostedTileTemplate, headers: hostedTileHeaders())
                .debugPanel()
                .camera(camera, position: NewYorkStoryboard.overview)
                .enableCameraUIControls(showChrome)
                .tourVideoRecorder(videoRecorder)
                // Depth-correct buildings instead of the default translucent
                // composite: the skyline is the hero of this post.
                .buildingExtrusionMode(.solid)
                // A cleaner cinematic frame: no house numbers and no POI
                // badges at the storyboard's street zooms.
                .labelSettings(cinematicLabelSettings)
                .mapStyle(cinematicMapStyle)
                // The flyover loops over the same Manhattan tiles: an enlarged
                // memory cache of GPU-ready tiles (1 GiB instead of 256 MiB)
                // so they are not evicted and re-uploaded between laps.
                .tileSettings(memoryCacheSizeInBytes: 1_073_741_824)
                .ignoresSafeArea()

            if showChrome {
                controls
                    .padding(16)
            }

            // Hidden hotkeys: R starts and stops the preview, Esc stops it.
            hotkeys
        }
        .task {
            await runAutoRenderIfRequested()
        }
    }

    /// Headless render hook for CLI and batch use: when
    /// `IMMERSIVE_POST_AUTORENDER_PATH` is set in the launch environment, the
    /// app renders the storyboard to that path on launch and terminates with
    /// a process exit code. `IMMERSIVE_POST_AUTORENDER_DRAFT=1` switches to a
    /// fast 640x360 12 fps draft, and `IMMERSIVE_POST_AUTORENDER_SHOTS=N`
    /// limits the render to the first N shots.
    private func runAutoRenderIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["IMMERSIVE_POST_AUTORENDER_PATH"] else {
            return
        }
        let configuration = environment["IMMERSIVE_POST_AUTORENDER_DRAFT"] == "1"
            ? ImmersiveMapVideoExportConfiguration(width: 640, height: 360, framesPerSecond: 12)
            : videoFormat.configuration
        var shots = NewYorkStoryboard.makeShots()
        if let shotLimit = environment["IMMERSIVE_POST_AUTORENDER_SHOTS"].flatMap(Int.init),
           shotLimit > 0, shotLimit < shots.count {
            shots = Array(shots.prefix(shotLimit))
        }
        do {
            // The recorder attaches to the map during the first SwiftUI
            // commit, which may land after this task starts: retry the
            // not-attached error briefly instead of sleeping a fixed delay.
            var attachAttemptsLeft = 50
            while true {
                do {
                    try await videoRecorder.export(shots: shots,
                                                   establish: NewYorkStoryboard.overview,
                                                   configuration: configuration,
                                                   to: URL(fileURLWithPath: path))
                    exit(0)
                } catch ImmersiveMapVideoExportError.notAttached where attachAttemptsLeft > 0 {
                    attachAttemptsLeft -= 1
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
        } catch {
            print("Autorender failed: \(error)")
            exit(1)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                togglePreview()
            } label: {
                Label(isTourRunning ? "Stop" : "Preview",
                      systemImage: isTourRunning ? "stop.circle.fill" : "play.circle.fill")
            }
            .keyboardShortcut("r", modifiers: [])

            if isRenderingVideo {
                ProgressView(value: renderFraction)
                    .frame(width: 120)
                Button {
                    videoRecorder.cancel()
                } label: {
                    Label("Cancel Render", systemImage: "xmark.circle.fill")
                }
            } else {
                Picker("Format", selection: $videoFormat) {
                    ForEach(VideoFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Button {
                    renderVideo()
                } label: {
                    Label("Render Video", systemImage: "film.circle.fill")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var hotkeys: some View {
        ZStack {
            Button("") { if isTourRunning { stopPreview() } }
                .keyboardShortcut(.escape, modifiers: [])
            if showChrome == false {
                Button("") { stopPreview() }
                    .keyboardShortcut("r", modifiers: [])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private func togglePreview() {
        if isTourRunning {
            stopPreview()
        } else {
            startPreview()
        }
    }

    private func startPreview() {
        let tour = tour ?? ImmersiveMapCameraTourController(camera: camera)
        self.tour = tour
        isTourRunning = true
        showChrome = false
        tour.start(shots: NewYorkStoryboard.makeShots(),
                   establish: NewYorkStoryboard.overview,
                   loop: true) {
            isTourRunning = false
            showChrome = true
        }
    }

    private func stopPreview() {
        tour?.stop()
    }

    /// Renders one lap of the storyboard offline in the selected format.
    private func renderVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "NewYorkFlyover.mov"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        isRenderingVideo = true
        renderFraction = 0
        videoRecorder.onProgress = { progress in
            renderFraction = progress.fractionCompleted
        }
        Task {
            defer {
                isRenderingVideo = false
            }
            do {
                try await videoRecorder.export(shots: NewYorkStoryboard.makeShots(),
                                               establish: NewYorkStoryboard.overview,
                                               configuration: videoFormat.configuration,
                                               to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                print("Flyover video render failed: \(error)")
                NSSound.beep()
            }
        }
    }
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
