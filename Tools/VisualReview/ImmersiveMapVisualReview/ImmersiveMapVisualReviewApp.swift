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
    /// How far through the queue the run is, so the progress can be shown as
    /// a bar rather than as a sentence that changes every half minute.
    var renderedCount = 0
    var renderQueueCount = 0
    /// The scenario whose map has to be on screen for a video export. The
    /// video recorder only works attached to a live view, so rendering a clip
    /// means showing that scene while it records.
    var videoScenarioOnScreen: VisualReviewScenario?
    var showsOnlyAttention = false
    /// Set when the verdict file could not be written, so the failure is on
    /// screen instead of only in the return value nobody reads.
    var verdictWriteFailure: String?

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
            renderedCount = 0
            renderQueueCount = 0
        }

        let directory = VisualReviewPaths.outputDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let queue = ids.map { wanted in items.filter { wanted.contains($0.id) } } ?? items
        renderQueueCount = queue.count
        renderedCount = 0
        for (index, item) in queue.enumerated() {
            renderedCount = index
            progressText = item.scenario.isVideo
                ? "\(item.scenario.title) (a video, this takes longer)"
                : item.scenario.title
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
            renderedCount = index + 1
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
        // Surfaced rather than swallowed. Writing the file is the one thing
        // this whole tool exists to do, and a discarded error means the row
        // turns green, the selection advances, and nothing was recorded: the
        // pass would look complete and leave no record of itself.
        do {
            try store.record(verdict, for: item.scenario.id)
            verdictWriteFailure = nil
        } catch {
            verdictWriteFailure = "Could not write \(VisualReviewPaths.verdictsURL.path): "
                + String(describing: error)
            return
        }
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
    @FocusState private var noteIsFocused: Bool

    /// A plain split rather than `NavigationSplitView`.
    ///
    /// Under `NavigationSplitView` on macOS 15 this window drew neither
    /// column's content: the scenario list was an empty black panel and the
    /// review controls under the artifact never appeared, while the view
    /// bodies were being evaluated normally (the item counts were right). The
    /// same views in a plain `HSplitView` draw correctly, so the tool does not
    /// use the container that breaks them. Nothing here needs what it offered:
    /// there is one fixed list, no navigation stack and no collapsing.
    var body: some View {
        // The progress strip is a sibling of the split rather than a
        // `safeAreaInset` on it. `HSplitView` is backed by `NSSplitView` and
        // does not pass a bottom safe-area inset down to its columns: the strip
        // came out floating over the review panel, cutting the verdict buttons
        // off the bottom of the window while a run was in flight. A stack
        // reserves the space it takes.
        VStack(spacing: 0) {
            HSplitView {
                sidebar
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                detail
                    .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.isRendering {
                Divider()
                renderingBanner
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    Task { await model.renderAll() }
                } label: {
                    Label("Render all", systemImage: "photo.on.rectangle.angled")
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.isRendering)
                .help("Render every scenario in the catalogue. Stills take a moment each, videos longer.")
            }
            ToolbarItem {
                Toggle(isOn: $model.showsOnlyAttention) {
                    Label("Needs a look (\(model.attentionCount))", systemImage: "eye")
                }
                .labelStyle(.titleAndIcon)
                .help("Show only scenarios whose render differs from the one they were approved for.")
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
        VStack(spacing: 0) {
            scenarioList
            Divider()
            // The counts are the sidebar's own witness: an empty list is then
            // always accompanied by the reason it is empty, instead of a
            // styled blank panel that looks the same whether the catalogue is
            // missing or the filter simply matched nothing.
            HStack {
                Text("\(model.items.count) scenarios")
                Spacer()
                Text("\(model.attentionCount) need a look")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var scenarioList: some View {
        List(selection: $model.selectedID) {
            ForEach(model.visibleItems) { item in
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
            }
        }
        .overlay {
            if model.visibleItems.isEmpty {
                if model.items.isEmpty {
                    ContentUnavailableView("No scenarios",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text("The catalogue is empty, which is a programming error."))
                } else {
                    ContentUnavailableView("Nothing needs a look",
                                           systemImage: "checkmark.seal",
                                           description: Text("Every scenario matches the render it was approved for. "
                                               + "Turn off \"Needs a look\" to see all \(model.items.count)."))
                }
            }
        }
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
                    .focused($noteIsFocused)

                Button {
                    model.record(.ok, note: "", for: item)
                    note = ""
                } label: {
                    Label("Approve (A)", systemImage: "checkmark")
                }
                // The shortcut carries no modifier, so it would swallow the
                // letter while a note is being typed; it is withdrawn for as
                // long as the field has focus.
                .verdictShortcut("a", isEnabled: noteIsFocused == false)
                .disabled(item.artifact == nil)
                .help("Record that this render looks right (A)")

                Button(role: .destructive) {
                    model.record(.notOk, note: note, for: item)
                    note = ""
                } label: {
                    Label("Reject (R)", systemImage: "xmark")
                }
                .verdictShortcut("r", isEnabled: noteIsFocused == false)
                // A rejection without a description is a note to nobody.
                .disabled(item.artifact == nil || note.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Record that this render is wrong (R). Needs a description first.")
            }

            if let failure = model.verdictWriteFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Rendering \(min(model.renderedCount + 1, max(model.renderQueueCount, 1))) "
                    + "of \(model.renderQueueCount)")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                Text(model.progressText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            ProgressView(value: Double(model.renderedCount),
                         total: Double(max(model.renderQueueCount, 1)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private extension View {
    /// A plain-letter shortcut that is withdrawn while text is being typed.
    ///
    /// Without a modifier the key reaches the button even when a `TextField`
    /// has focus, so leaving it installed would make the rejection note
    /// impossible to write: pressing "r" would reject rather than type.
    @ViewBuilder
    func verdictShortcut(_ key: KeyEquivalent, isEnabled: Bool) -> some View {
        if isEnabled {
            keyboardShortcut(key, modifiers: [])
        } else {
            self
        }
    }
}

/// The ground behind a render, so transparent space reads as transparent
/// rather than as whatever colour the window happens to be.
private struct CheckerboardBackground: View {
    /// Drawn as a plain `Shape` rather than in a `Canvas`.
    ///
    /// The `Canvas` version painted over the view it was a background of: the
    /// artifact and the "not rendered yet" placeholder both came out washed
    /// under a 90% white veil. A shape composites where a background is
    /// supposed to, behind its content.
    private struct CheckerSquares: Shape {
        let square: Double

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let columns = Int(ceil(rect.width / square))
            let rows = Int(ceil(rect.height / square))
            guard columns > 0, rows > 0 else {
                return path
            }
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    path.addRect(CGRect(x: Double(column) * square,
                                        y: Double(row) * square,
                                        width: square,
                                        height: square))
                }
            }
            return path
        }
    }

    var body: some View {
        Color.white.opacity(0.9)
            .overlay {
                CheckerSquares(square: 12)
                    .fill(Color.black.opacity(0.08))
            }
    }
}
