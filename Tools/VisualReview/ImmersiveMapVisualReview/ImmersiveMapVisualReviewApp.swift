// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import AVKit
import ImmersiveMap
import SwiftUI

@main
struct ImmersiveMapVisualReviewApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap Visual Review") {
            VisualReviewScreen()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowResizability(.contentMinSize)
    }
}

/// What the tool knows about one scenario right now.
@MainActor
@Observable
final class VisualReviewItem: Identifiable {
    enum State: Equatable {
        /// Not rendered in this session yet.
        case pending
        case rendering
        case failed(String)
        case rendered
    }

    /// Stored rather than forwarded from `scenario`: `Identifiable` is read
    /// from outside the main actor, and reaching through an isolated property
    /// to answer it would cross isolation for a string that never changes.
    nonisolated let id: String
    let scenario: VisualReviewScenario
    var state: State = .pending
    var artifact: VisualReviewArtifact?
    var verdict: VisualReviewVerdict?

    init(scenario: VisualReviewScenario, verdict: VisualReviewVerdict?) {
        self.id = scenario.id
        self.scenario = scenario
        self.verdict = verdict
    }

    /// Whether the picture on disk is the one the verdict was given for.
    ///
    /// This is what keeps a pre-release pass short: everything that still
    /// matches its approval can be skipped, and attention goes to what moved.
    var isUnchangedSinceVerdict: Bool {
        guard let artifact, let verdict else { return false }
        return artifact.fingerprint == verdict.fingerprint
    }

    var needsAttention: Bool {
        guard case .rendered = state else { return false }
        return isUnchangedSinceVerdict == false
    }

    var statusSymbol: String {
        switch state {
        case .pending: return "circle.dashed"
        case .rendering: return "circle.dotted"
        case .failed: return "exclamationmark.triangle.fill"
        case .rendered:
            guard let verdict else { return "questionmark.circle" }
            if isUnchangedSinceVerdict == false { return "arrow.triangle.2.circlepath" }
            return verdict.ruling == .ok ? "checkmark.circle.fill" : "xmark.circle.fill"
        }
    }

    var statusColor: Color {
        switch state {
        case .pending: return .secondary
        case .rendering: return .accentColor
        case .failed: return .orange
        case .rendered:
            guard let verdict else { return .secondary }
            if isUnchangedSinceVerdict == false { return .yellow }
            return verdict.ruling == .ok ? .green : .red
        }
    }
}

@MainActor
@Observable
final class VisualReviewModel {
    var items: [VisualReviewItem] = []
    var selectedID: String?
    var isRendering = false
    var progressText = ""
    /// The scenario whose map has to be on screen for a video export. The
    /// video recorder only works attached to a live view, so rendering a clip
    /// means showing that scene while it records.
    var videoScenarioOnScreen: VisualReviewScenario?
    var showsOnlyAttention = false

    private var store: VisualReviewVerdictStore
    private let renderer = VisualReviewRenderer()
    let videoRecorder = ImmersiveMapTourVideoRecorder()

    init() {
        store = VisualReviewVerdictStore(url: VisualReviewPaths.verdictsURL)
        items = VisualReviewCatalogue.scenarios.map {
            VisualReviewItem(scenario: $0, verdict: store[$0.id])
        }
        selectedID = items.first?.id
    }

    var visibleItems: [VisualReviewItem] {
        showsOnlyAttention ? items.filter(\.needsAttention) : items
    }

    var selectedItem: VisualReviewItem? {
        items.first { $0.id == selectedID }
    }

    var attentionCount: Int {
        items.filter(\.needsAttention).count
    }

    // MARK: - Rendering

    /// Renders everything, stills first.
    ///
    /// Stills go through the headless still recorder and need nothing on
    /// screen, so they run back to back. Each video then takes a turn with the
    /// live map, because that is the only way the video recorder can attach.
    ///
    /// - Parameter only: render just these scenario ids. Used by the headless
    ///   hook to render a subset without editing the catalogue.
    func renderAll(only ids: Set<String>? = nil) async {
        guard isRendering == false else { return }
        isRendering = true
        defer {
            isRendering = false
            videoScenarioOnScreen = nil
            progressText = ""
        }

        let directory = VisualReviewPaths.outputDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let queue = ids.map { wanted in items.filter { wanted.contains($0.id) } } ?? items
        for (index, item) in queue.enumerated() {
            progressText = "Rendering \(index + 1) of \(queue.count): \(item.scenario.title)"
            item.state = .rendering
            do {
                switch item.scenario.subject {
                case let .still(camera, routes):
                    item.artifact = try await renderer.renderStill(item.scenario,
                                                                   camera: camera,
                                                                   routes: routes,
                                                                   into: directory)
                case let .video(establish, shots):
                    videoScenarioOnScreen = item.scenario
                    // Cleared however the export ends. Left mounted after a
                    // failure, the live map would keep rendering underneath
                    // every still that follows in the queue: extra GPU work
                    // during a capture, in a tool whose whole point is output
                    // that does not vary between runs.
                    defer { videoScenarioOnScreen = nil }
                    // Give SwiftUI a commit to put the scene on screen and let
                    // the recorder bind to it before the export starts.
                    try? await Task.sleep(for: .milliseconds(300))
                    item.artifact = try await renderer.renderVideo(item.scenario,
                                                                   establish: establish,
                                                                   shots: shots,
                                                                   recorder: videoRecorder,
                                                                   into: directory)
                }
                item.state = .rendered
            } catch {
                item.state = .failed(String(describing: error))
            }
        }
        selectedID = items.first(where: \.needsAttention)?.id ?? selectedID
    }

    /// Picks up artifacts left by an earlier run so the app opens with the
    /// last render already reviewable instead of blank.
    ///
    /// The fingerprint is recomputed from the file rather than copied from the
    /// verdict. Copying it would make every adopted render claim to be the one
    /// that was approved, which is exactly the lie this tool exists to avoid:
    /// a render produced after the approval, then reviewed in a later session,
    /// would present itself as unchanged and be skipped.
    func adoptExistingRenders() async {
        let directory = VisualReviewPaths.outputDirectory
        for item in items {
            let suffix = item.scenario.isVideo ? "mov" : "png"
            let url = directory.appending(path: "\(item.scenario.id).\(suffix)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            let fingerprint: String?
            if item.scenario.isVideo {
                fingerprint = await VisualReviewFingerprint.ofVideo(at: url)
            } else {
                fingerprint = VisualReviewFingerprint.ofImageFile(at: url)
            }
            guard let fingerprint else { continue }

            item.artifact = VisualReviewArtifact(scenarioID: item.scenario.id,
                                                 url: url,
                                                 fingerprint: fingerprint)
            item.state = .rendered
        }
        selectedID = items.first(where: \.needsAttention)?.id ?? selectedID
    }

    // MARK: - Verdicts

    func record(_ ruling: VisualReviewVerdict.Ruling, note: String, for item: VisualReviewItem) {
        guard let artifact = item.artifact else { return }
        let verdict = VisualReviewVerdict(ruling: ruling,
                                          note: note,
                                          decidedAt: Date(),
                                          fingerprint: artifact.fingerprint,
                                          commit: VisualReviewPaths.currentCommit())
        item.verdict = verdict
        try? store.record(verdict, for: item.scenario.id)
        advanceSelection(from: item)
    }

    private func advanceSelection(from item: VisualReviewItem) {
        let list = visibleItems
        guard let index = list.firstIndex(where: { $0.id == item.id }) else { return }
        let next = list.dropFirst(index + 1).first ?? list.first { $0.id != item.id }
        selectedID = next?.id ?? item.id
    }
}

struct VisualReviewScreen: View {
    @State private var model = VisualReviewModel()
    @State private var note = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    Task { await model.renderAll() }
                } label: {
                    Label("Render all", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(model.isRendering)
            }
            ToolbarItem {
                Toggle(isOn: $model.showsOnlyAttention) {
                    Label("Needs a look (\(model.attentionCount))", systemImage: "eye")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if model.isRendering {
                renderingBanner
            }
        }
        // The map a video export attaches to. The export renders in its own
        // headless engine, so this one never has to be looked at; it exists
        // only because the recorder binds to a live view and reads the
        // settings from it. Hence a real frame (SwiftUI must instantiate it)
        // at an opacity that keeps it out of the way.
        .background {
            if let scenario = model.videoScenarioOnScreen {
                ImmersiveMapView()
                    .applying(scenario.settings)
                    .tourVideoRecorder(model.videoRecorder)
                    .frame(width: 640, height: 360)
                    .opacity(0.001)
                    .allowsHitTesting(false)
            }
        }
        // Selection drives the note field, and it has to be here rather than
        // on the detail view: the detail is rebuilt on selection change, so a
        // modifier inside it would miss the transition it is meant to observe
        // and leave the previous scenario's note in the box.
        .task(id: model.selectedID) {
            note = model.selectedItem?.verdict?.note ?? ""
        }
        .task {
            await model.adoptExistingRenders()
            await runHeadlessRenderIfRequested()
        }
    }

    /// Batch hook, in the shape the `Posts/` apps already use: launching with
    /// `IMMERSIVE_VISUAL_REVIEW_RENDER=1` renders the catalogue and exits with
    /// a process status, no clicks involved. `IMMERSIVE_VISUAL_REVIEW_ONLY`
    /// takes a comma separated list of scenario ids to render instead of all
    /// of them.
    ///
    /// Rendering and reviewing are separate acts, and this is the seam between
    /// them: renders can be produced unattended (overnight, from a script,
    /// before you sit down) and judged later.
    private func runHeadlessRenderIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["IMMERSIVE_VISUAL_REVIEW_RENDER"] == "1" else {
            return
        }
        let only = environment["IMMERSIVE_VISUAL_REVIEW_ONLY"]
            .map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }

        await model.renderAll(only: only)

        var failures = 0
        for item in model.items {
            switch item.state {
            case let .failed(message):
                failures += 1
                print("FAILED  \(item.id): \(message)")
            case .rendered:
                print("ok      \(item.id)  \(item.artifact?.fingerprint.prefix(16) ?? "")")
            case .pending, .rendering:
                continue
            }
        }
        print(failures == 0 ? "All requested scenarios rendered." : "\(failures) scenario(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }

    private var sidebar: some View {
        List(model.visibleItems, selection: $model.selectedID) { item in
            HStack(spacing: 8) {
                Image(systemName: item.statusSymbol)
                    .foregroundStyle(item.statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.scenario.title)
                    if item.scenario.isVideo {
                        Text("video")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tag(item.id)
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 300)
    }

    @ViewBuilder
    private var detail: some View {
        if let item = model.selectedItem {
            VStack(alignment: .leading, spacing: 0) {
                artifactView(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CheckerboardBackground())
                Divider()
                reviewPanel(for: item)
                    .padding(16)
            }
        } else {
            ContentUnavailableView("Nothing to review",
                                   systemImage: "checkmark.seal",
                                   description: Text("Every scenario matches the picture it was approved for."))
        }
    }

    @ViewBuilder
    private func artifactView(for item: VisualReviewItem) -> some View {
        switch item.state {
        case .pending:
            ContentUnavailableView("Not rendered yet",
                                   systemImage: "photo",
                                   description: Text("Press Render all."))
        case .rendering:
            ProgressView("Rendering")
        case let .failed(message):
            ContentUnavailableView("Render failed", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .rendered:
            if let artifact = item.artifact {
                if item.scenario.isVideo {
                    VideoPlayer(player: AVPlayer(url: artifact.url))
                } else if let image = NSImage(contentsOf: artifact.url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ContentUnavailableView("Could not read the render", systemImage: "photo.badge.exclamationmark")
                }
            }
        }
    }

    private func reviewPanel(for item: VisualReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.scenario.title)
                .font(.headline)
            Text(item.scenario.lookFor)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let verdict = item.verdict {
                HStack(spacing: 6) {
                    Image(systemName: item.statusSymbol).foregroundStyle(item.statusColor)
                    Text(verdictSummary(verdict, unchanged: item.isUnchangedSinceVerdict))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                TextField("What is wrong with it", text: $note)
                    .textFieldStyle(.roundedBorder)

                Button {
                    model.record(.ok, note: "", for: item)
                    note = ""
                } label: {
                    Label("Looks right", systemImage: "checkmark")
                }
                .keyboardShortcut("k", modifiers: [])
                .disabled(item.artifact == nil)

                Button(role: .destructive) {
                    model.record(.notOk, note: note, for: item)
                    note = ""
                } label: {
                    Label("Not right", systemImage: "xmark")
                }
                .keyboardShortcut("j", modifiers: [])
                // A rejection without a description is a note to nobody.
                .disabled(item.artifact == nil || note.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func verdictSummary(_ verdict: VisualReviewVerdict, unchanged: Bool) -> String {
        let ruling = verdict.ruling == .ok ? "approved" : "rejected"
        let commit = verdict.commit.map { " at \($0)" } ?? ""
        let state = unchanged ? "unchanged since" : "changed since"
        let note = verdict.note.isEmpty ? "" : ": \(verdict.note)"
        return "\(state) \(ruling)\(commit)\(note)"
    }

    private var renderingBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(model.progressText)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(16)
    }
}

/// The ground behind a render, so transparent space reads as transparent
/// rather than as whatever colour the window happens to be.
private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let square = 12.0
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.9)))
            for row in 0...Int(size.height / square) {
                for column in 0...Int(size.width / square) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: Double(column) * square,
                                      y: Double(row) * square,
                                      width: square,
                                      height: square)
                    context.fill(Path(rect), with: .color(.black.opacity(0.08)))
                }
            }
        }
    }
}
