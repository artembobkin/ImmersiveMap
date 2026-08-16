// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImmersiveMap

@main
struct CrowdBloomApp: App {
    var body: some Scene {
        WindowGroup("Crowd Bloom") {
            CrowdScreen()
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

/// The avatar post scene: fifty markers over the Eixample that group themselves
/// into flowers and come apart again as the camera crosses fifteen zoom levels.
/// `CrowdStoryboard` plays as a looped on-screen preview (started with the
/// button or the R key, stopped with R again, Esc, or any gesture on the map),
/// and "Render Video" writes one lap of the same storyboard to a QuickTime file
/// offline while the on-screen map stays fully interactive.
private struct CrowdScreen: View {
    @Environment(\.displayScale) private var displayScale

    @State private var camera = ImmersiveMapCameraController()
    @State private var avatars = ImmersiveMapAvatarsController()
    @State private var tour: ImmersiveMapCameraTourController?
    @State private var videoRecorder = ImmersiveMapTourVideoRecorder()
    // 1080p rather than 4K, unlike the other posts: see `CrowdScale`. Both
    // render the same framing and the same layout, but a 4K frame draws the
    // portraits at twice the pixel size for the same share of the picture, so
    // this is the format the post is composed for.
    @State private var videoFormat: VideoFormat = .widescreen1080p
    @State private var isTourRunning = false
    @State private var isRenderingVideo = false
    @State private var renderFraction: Double = 0
    @State private var showChrome = true
    @State private var previewHeightPoints: Double = 800
    /// Set for the duration of an export: the avatar settings the recorder
    /// snapshots have to be sized for the output frame, not for the window.
    @State private var exportFrameHeightPx: Double?

    private var frameHeightPx: Double {
        exportFrameHeightPx ?? max(1, previewHeightPoints * Double(displayScale))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ImmersiveMapView()
                .tileURLTemplate(hostedTileTemplate, headers: hostedTileHeaders())
                .debugPanel()
                .camera(camera, position: CrowdStoryboard.globe)
                .enableCameraUIControls(showChrome)
                .tourVideoRecorder(videoRecorder)
                .avatars(avatars)
                // Everything here is in drawable pixels, so all of it is
                // derived from the height of the frame being rendered. That is
                // what keeps the crowd blooming at the same zoom, and therefore
                // at the same second, in the window and in every export format.
                .avatarSettings(size: CrowdScale.size,
                                sizeScale: CrowdScale.sizeScale(frameHeightPx: frameHeightPx),
                                borderWidthPx: CrowdScale.borderWidthPx(frameHeightPx: frameHeightPx),
                                maxOffsetPx: CrowdScale.maxOffsetPx(frameHeightPx: frameHeightPx))
                // The storyboard crosses fifteen zoom levels twice per lap and
                // comes back over the same ground: an enlarged memory cache of
                // GPU-ready tiles (1 GiB instead of 256 MiB) keeps the low
                // zooms from being evicted by the high ones and re-uploaded on
                // the way back up.
                .tileSettings(memoryCacheSizeInBytes: 1_073_741_824)
                .onGeometryChange(for: Double.self) { proxy in
                    proxy.size.height
                } action: { height in
                    previewHeightPoints = height
                }
                .ignoresSafeArea()

            if showChrome {
                controls
                    .padding(16)
            }

            // Hidden hotkeys: R starts and stops the preview, Esc stops it.
            hotkeys
        }
        .task {
            avatars.set(CrowdPeople.makeMarkers())
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
        var shots = CrowdStoryboard.makeShots()
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
                    try await export(shots: shots,
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

    /// Runs one export with the avatar settings sized for the output frame.
    ///
    /// The recorder snapshots the view's settings once, when `export` is
    /// called, so the frame-height override has to be in place by then: it is
    /// published as SwiftUI state, which reaches the host view on a later
    /// commit, and the sleep is that commit. The on-screen map visibly changes
    /// marker size for the duration of the render, which is the same settings
    /// change being applied to the live engine as well.
    private func export(shots: [ImmersiveMapCameraTourShot],
                        configuration: ImmersiveMapVideoExportConfiguration,
                        to url: URL) async throws {
        exportFrameHeightPx = Double(configuration.height)
        defer { exportFrameHeightPx = nil }
        try await Task.sleep(for: .milliseconds(150))
        try await videoRecorder.export(shots: shots,
                                       establish: CrowdStoryboard.globe,
                                       configuration: configuration,
                                       to: url)
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
        tour.start(shots: CrowdStoryboard.makeShots(),
                   establish: CrowdStoryboard.globe,
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
        panel.nameFieldStringValue = "CrowdBloom.mov"
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
                try await export(shots: CrowdStoryboard.makeShots(),
                                 configuration: videoFormat.configuration,
                                 to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                print("Crowd video render failed: \(error)")
                NSSound.beep()
            }
        }
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
