// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import AVKit
import CoreGraphics
import ImageIO
import ImmersiveMap
import SwiftUI

@main
struct ImmersiveMapVisualReviewApp: App {
    #if os(macOS)
    var body: some Scene {
        WindowGroup("ImmersiveMap Visual Review") {
            VisualReviewScreen()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowResizability(.contentMinSize)
    }
    #else
    var body: some Scene {
        WindowGroup("ImmersiveMap Visual Review") {
            VisualReviewScreen()
        }
    }
    #endif
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
    /// The zip a finished pass is handed back as, once it has been built.
    var reportURL: URL?
    var isPreparingReport = false
    var reportFailure: String?

    /// When the last verdict was recorded, to tell a decision from a key that
    /// is simply still held down. Well under the pace of someone looking at
    /// each picture, well over the system's auto-repeat interval.
    private var lastVerdictDate: Date?
    private static let minimumTimeBetweenVerdicts: TimeInterval = 0.4

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

    /// Whether anything has been rendered at all, which is what separates a
    /// session that has not started from one that is under way.
    var hasAnyRender: Bool {
        items.contains { $0.artifact != nil }
    }

    /// The next thing the guided pass should put in front of the reviewer: the
    /// first scenario, in catalogue order, whose render nobody has judged yet.
    var nextNeedingAttention: VisualReviewItem? {
        items.first(where: \.needsAttention)
    }

    /// Renders that never happened, which the finish screen has to say out
    /// loud: a scenario that failed to render was not judged, and a pass that
    /// quietly omits it reads as a clean sheet.
    var failedItems: [VisualReviewItem] {
        items.filter { if case .failed = $0.state { return true } else { return false } }
    }

    var rejectedItems: [VisualReviewItem] {
        items.filter { $0.verdict?.ruling == .notOk && $0.isUnchangedSinceVerdict }
    }

    var approvedCount: Int {
        items.filter { $0.verdict?.ruling == .ok && $0.isUnchangedSinceVerdict }.count
    }

    // MARK: - Report

    /// Assembles the pass into one zip: the judgements, the pictures they were
    /// made about, and the machine that rendered them.
    func prepareReport() async {
        guard isPreparingReport == false else { return }
        isPreparingReport = true
        defer { isPreparingReport = false }
        do {
            reportURL = try await VisualReviewReportBuilder.makeReport(for: items)
            reportFailure = nil
        } catch {
            reportURL = nil
            reportFailure = String(describing: error)
        }
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
        // The pictures are about to change, so a report built from the old ones
        // describes a pass that no longer exists.
        reportURL = nil
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

    /// - Returns: whether the verdict was actually recorded. A guided pass
    ///   advances on that answer rather than on the button having been pressed:
    ///   a dropped key repeat or a failed write must not move the reviewer on
    ///   from a scenario nothing was written about.
    @discardableResult
    func record(_ ruling: VisualReviewVerdict.Ruling, note: String, for item: VisualReviewItem) -> Bool {
        guard let artifact = item.artifact else { return false }
        // A verdict is a decision, and a held key is not twelve of them.
        //
        // Approving advances the selection, so with the shortcut on a bare
        // letter the system's key auto-repeat walks the entire catalogue: one
        // leaned-on "A" approved all twelve scenarios inside two seconds,
        // which is a record of nothing. Repeats inside the window are dropped,
        // and the list shows what did register.
        let now = Date()
        if let last = lastVerdictDate, now.timeIntervalSince(last) < Self.minimumTimeBetweenVerdicts {
            return false
        }
        lastVerdictDate = now
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
            return false
        }
        // Any report built before this verdict no longer describes the pass.
        reportURL = nil
        advanceSelection(from: item)
        return true
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

    /// Set while the review screen is pushed on a phone, where the list and the
    /// artifact cannot share a screen. Verdicts advance the selection, so the
    /// pushed screen follows the catalogue and one push covers the whole pass.
    @State private var isReviewing = false

    /// Set when the reviewer asks to see the catalogue after a finished pass,
    /// so the finish screen steps aside instead of reappearing the moment
    /// everything is judged.
    @State private var isBrowsing = false

    var body: some View {
        platformBody
            // The map a video export attaches to. The export renders in its own
            // headless engine, so this one never has to be looked at; it exists
            // only because the recorder binds to a live view and reads the
            // settings from it. Hence a real frame (SwiftUI must instantiate
            // it) at an opacity that keeps it out of the way.
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
            // Selection drives the note field, and it has to be here rather
            // than on the detail view: the detail is rebuilt on selection
            // change, so a modifier inside it would miss the transition it is
            // meant to observe and leave the previous scenario's note in the
            // box.
            .task(id: model.selectedID) {
                note = model.selectedItem?.verdict?.note ?? ""
            }
            .task {
                await model.adoptExistingRenders()
                await runHeadlessRenderIfRequested()
            }
    }

    #if os(macOS)
    /// A plain split rather than `NavigationSplitView`.
    ///
    /// Under `NavigationSplitView` on macOS 15 this window drew neither
    /// column's content: the scenario list was an empty black panel and the
    /// review controls under the artifact never appeared, while the view
    /// bodies were being evaluated normally (the item counts were right). The
    /// same views in a plain `HSplitView` draw correctly, so the tool does not
    /// use the container that breaks them. Nothing here needs what it offered:
    /// there is one fixed list, no navigation stack and no collapsing.
    private var platformBody: some View {
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
            ToolbarItem(placement: .navigation) { renderAllButton }
            ToolbarItem { attentionToggle }
            ToolbarItem { shareVerdictsButton }
            ToolbarItem { reportToolbarControl }
        }
    }
    #else
    /// One screen at a time on a phone, and one thing to do on each of them.
    ///
    /// A helper who agreed to spend half an hour on this should not have to
    /// know what the catalogue is, which button starts a render, or where the
    /// verdict file ends up. The phone build is therefore a guided pass: press
    /// start, wait, judge each picture as it comes, send the report. The
    /// catalogue list is still there behind it for a session that was
    /// interrupted, but nobody has to go through it to finish a pass.
    ///
    /// A 1600 by 1000 render and a list of twelve scenarios also do not share a
    /// phone screen, and the review screen is the one that has to be big: the
    /// whole point of a device pass is judging the rendering on the hardware
    /// that produced it.
    private var platformBody: some View {
        NavigationStack {
            Group {
                if model.isRendering {
                    renderingScreen
                } else if model.hasAnyRender == false {
                    welcomeScreen
                } else if model.attentionCount == 0 && isBrowsing == false {
                    finishScreen
                } else {
                    VStack(spacing: 0) {
                        scenarioList
                        Divider()
                        countsFooter
                    }
                }
            }
            .navigationTitle("ImmersiveMap check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.hasAnyRender, model.isRendering == false {
                    ToolbarItem(placement: .topBarLeading) { renderAllButton }
                    ToolbarItem(placement: .topBarTrailing) { attentionToggle }
                }
            }
            .navigationDestination(isPresented: $isReviewing) {
                detail
                    .navigationTitle(model.selectedItem?.scenario.title ?? "Review")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    /// The first screen a helper sees, and the only instruction they need.
    private var welcomeScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Thank you for looking at this")
                    .font(.title2.weight(.semibold))
                Text("The map engine renders \(model.items.count) fixed scenes on this phone. "
                    + "Nobody can tell from a test whether a shadow looks like a shadow or a "
                    + "label is readable, so a person has to look.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Press start and leave the phone alone for a few minutes while it renders.")
                    step(2, "You then get one picture at a time, with a sentence saying what to look at. "
                        + "Approve it, or reject it and say what is wrong.")
                    step(3, "At the end, send the report back. It is one file.")
                }
                Button {
                    startGuidedPass()
                } label: {
                    Label("Start the check", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("Keep the app in the foreground and the phone plugged in if you can. "
                    + "Rendering is the part that takes a while; judging is quick.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// While the catalogue renders, which is minutes rather than seconds.
    private var renderingScreen: some View {
        VStack(spacing: 20) {
            ProgressView(value: Double(model.renderedCount),
                         total: Double(max(model.renderQueueCount, 1)))
                .progressViewStyle(.linear)
            Text("Rendering \(min(model.renderedCount + 1, max(model.renderQueueCount, 1))) "
                + "of \(model.renderQueueCount)")
                .font(.headline)
                .monospacedDigit()
            Text(model.progressText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("The review starts by itself when this finishes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }

    /// The end of a pass: what was decided, and the one file to send back.
    private var finishScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(model.rejectedItems.isEmpty && model.failedItems.isEmpty
                    ? "Everything looked right"
                    : "That is everything")
                    .font(.title2.weight(.semibold))
                Text("\(model.approvedCount) approved, \(model.rejectedItems.count) rejected, "
                    + "\(model.failedItems.count) failed to render, "
                    + "out of \(model.items.count) scenes.")
                    .foregroundStyle(.secondary)

                ForEach(model.rejectedItems) { item in
                    Label("\(item.scenario.title): \(item.verdict?.note ?? "")",
                          systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                ForEach(model.failedItems) { item in
                    Label("\(item.scenario.title) did not render",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }

                reportControl

                Button {
                    isBrowsing = true
                } label: {
                    Label("Look at the scenes again", systemImage: "list.bullet")
                }
                Button {
                    startGuidedPass()
                } label: {
                    Label("Render everything again", systemImage: "arrow.clockwise")
                }
            }
            .padding(20)
        }
    }
    #endif

    #if os(macOS)
    /// The same two steps as on a phone, folded into one toolbar item. A Mac
    /// pass is made by whoever owns the checkout, and the renders are already
    /// sitting in it, but a report is still the way to send a pass to someone
    /// else without describing where the files are.
    @ViewBuilder
    private var reportToolbarControl: some View {
        if let url = model.reportURL {
            ShareLink(item: url) {
                Label("Send the report", systemImage: "square.and.arrow.up.on.square")
            }
            .toolbarLabelStyle()
        } else {
            Button {
                Task { await model.prepareReport() }
            } label: {
                Label(model.isPreparingReport ? "Packing the report" : "Make the report",
                      systemImage: "shippingbox")
            }
            .toolbarLabelStyle()
            .disabled(model.isPreparingReport || model.hasAnyRender == false)
            .help("Pack the judgements, the renders and the build they came from into one zip.")
        }
    }
    #endif

    /// Builds the report, then hands it to the share sheet.
    ///
    /// Two steps rather than one because a zip of a dozen renders takes a
    /// moment to write, and `ShareLink` needs the file before it can offer it.
    /// Both steps say what they are, which is the part that matters.
    @ViewBuilder
    private var reportControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = model.reportURL {
                ShareLink(item: url) {
                    Label("Send the report", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("\(url.lastPathComponent): the judgements, every render they were "
                    + "made about, and which device and build produced them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await model.prepareReport() }
                } label: {
                    Label(model.isPreparingReport ? "Packing the report" : "Make the report",
                          systemImage: "shippingbox")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isPreparingReport || model.hasAnyRender == false)
            }
            if let failure = model.reportFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Renders the whole catalogue and walks straight into the review.
    ///
    /// The two are one action on purpose. A pass that renders and then waits to
    /// be told to continue is a pass that gets left half done on a phone that
    /// went to sleep on a table.
    private func startGuidedPass() {
        isBrowsing = false
        Task {
            await model.renderAll()
            model.showsOnlyAttention = false
            guard let next = model.nextNeedingAttention else { return }
            model.selectedID = next.id
            isReviewing = true
        }
    }

    // MARK: - Controls

    private var renderAllButton: some View {
        Button {
            Task { await model.renderAll() }
        } label: {
            Label("Render all", systemImage: "photo.on.rectangle.angled")
        }
        .labelStyle(.titleAndIcon)
        .disabled(model.isRendering)
        .help("Render every scenario in the catalogue. Stills take a moment each, videos longer.")
    }

    private var attentionToggle: some View {
        Toggle(isOn: $model.showsOnlyAttention) {
            Label("Needs a look (\(model.attentionCount))", systemImage: "eye")
        }
        .toolbarLabelStyle()
        .help("Show only scenarios whose render differs from the one they were approved for.")
    }

    /// How a pass leaves the device.
    ///
    /// On a phone the verdict file lives in the app's own container, which the
    /// checkout it belongs in cannot reach, so the file itself goes to the
    /// share sheet: AirDrop it to the Mac, or save it into Files and move it
    /// into `Tools/VisualReview/`. On a Mac it is already in the checkout and
    /// this is just a quick way to send it to someone.
    private var shareVerdictsButton: some View {
        ShareLink(item: VisualReviewPaths.verdictsURL) {
            Label("Share verdicts", systemImage: "square.and.arrow.up")
        }
        .toolbarLabelStyle()
        // Nothing has been written yet, so there is no file to hand over.
        .disabled(model.items.allSatisfy { $0.verdict == nil })
        .help("Send \(VisualReviewPaths.verdictsFileName) somewhere: AirDrop to the Mac, or save it to Files.")
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
        // `IMMERSIVE_VISUAL_REVIEW_REPORT=1` packs the result the same way the
        // button does. Nothing has been judged in a headless run, so the report
        // is a record of what rendered rather than of a pass, which is what
        // makes it worth having: it is how a render made on one machine gets
        // sent to the person who will look at it on another.
        if environment["IMMERSIVE_VISUAL_REVIEW_REPORT"] == "1" {
            await model.prepareReport()
            if let url = model.reportURL {
                print("report  \(url.path)")
            } else {
                failures += 1
                print("FAILED  report: \(model.reportFailure ?? "unknown")")
            }
        }

        print(failures == 0 ? "All requested scenarios rendered." : "\(failures) scenario(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }

    #if os(macOS)
    private var sidebar: some View {
        VStack(spacing: 0) {
            scenarioList
            Divider()
            countsFooter
        }
    }
    #endif

    /// The counts are the list's own witness: an empty list is then always
    /// accompanied by the reason it is empty, instead of a styled blank panel
    /// that looks the same whether the catalogue is missing or the filter
    /// simply matched nothing.
    private var countsFooter: some View {
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

    private var scenarioList: some View {
        #if os(macOS)
        List(selection: $model.selectedID) {
            ForEach(model.visibleItems) { item in
                scenarioRow(for: item)
            }
        }
        .overlay { listEmptyState }
        #else
        // Tapping pushes the review screen rather than selecting in place:
        // `List(selection:)` on iOS is multi-select in edit mode, not a
        // pointer to what the detail should show.
        List {
            ForEach(model.visibleItems) { item in
                Button {
                    model.selectedID = item.id
                    isReviewing = true
                } label: {
                    HStack {
                        scenarioRow(for: item)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay { listEmptyState }
        #endif
    }

    private func scenarioRow(for item: VisualReviewItem) -> some View {
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

    @ViewBuilder
    private var listEmptyState: some View {
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
                } else if let image = VisualReviewArtifactImage.load(artifact.url) {
                    image
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
                    recordVerdict(.ok, note: "", for: item)
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
                    recordVerdict(.notOk, note: note, for: item)
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

    /// Records a verdict and, on a phone, moves the guided pass along.
    ///
    /// The advance is conditional on the verdict having been written. A key
    /// repeat that was dropped, or a verdict file that could not be saved,
    /// leaves the reviewer on the scene they are looking at rather than pushing
    /// them past a picture nothing was recorded about.
    private func recordVerdict(_ ruling: VisualReviewVerdict.Ruling,
                               note text: String,
                               for item: VisualReviewItem) {
        let recorded = model.record(ruling, note: text, for: item)
        guard recorded else { return }
        note = ""
        #if !os(macOS)
        if let next = model.nextNeedingAttention {
            model.selectedID = next.id
        } else {
            // Nothing left to judge: back out to the finish screen, which is
            // where the report is made.
            isReviewing = false
        }
        #endif
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

/// Loads a rendered artifact as a SwiftUI image.
///
/// Through `CGImageSource` rather than `NSImage` or `UIImage`, so both
/// platforms take the same path. The tool renders the same catalogue on a Mac
/// and on a phone, and a picture that arrives on screen differently between
/// them is exactly what a visual review must not introduce itself.
enum VisualReviewArtifactImage {
    static func load(_ url: URL) -> Image? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return Image(decorative: image, scale: 1)
    }
}

private extension View {
    /// Titles on a Mac, where the toolbar has room for them, icons on a phone,
    /// where three of them do not fit across the top of the screen.
    @ViewBuilder
    func toolbarLabelStyle() -> some View {
        #if os(macOS)
        labelStyle(.titleAndIcon)
        #else
        labelStyle(.iconOnly)
        #endif
    }

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
