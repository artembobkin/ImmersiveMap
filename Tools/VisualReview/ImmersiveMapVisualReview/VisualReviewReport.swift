// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
#if canImport(UIKit)
import UIKit
#endif

/// What a pass produced, as one file somebody can hand back.
///
/// The verdict file on its own is not a report. It says `notOk` and a sentence,
/// and the picture that sentence is about lives in a folder on the reviewer's
/// machine, which on a phone is a container nobody thinks to open. A person who
/// agreed to spend twenty minutes looking at renders should end the pass with
/// one thing to send: the judgements, the pictures they were made about, and
/// enough about the machine to tell a driver difference from a regression.
struct VisualReviewReport: Codable {
    struct Environment: Codable {
        /// Hardware the renders came off, as the model identifier
        /// (`iPhone17,1`, `Mac16,10`). The marketing name is not available
        /// without a table that goes stale, and the identifier is the one a bug
        /// report can be searched by.
        var machine: String
        var systemName: String
        var systemVersion: String
        /// Name the Metal device reports, which is what actually rasterized
        /// every pixel in the folder.
        var gpu: String?
        /// Checkout the app was built from. On a phone this is stamped into
        /// Info.plist by a build phase, since there is no git to ask.
        var commit: String?
        var appVersion: String?
    }

    struct Entry: Codable {
        enum Outcome: String, Codable {
            /// Rendered and judged in this pass.
            case approved
            case rejected
            /// Rendered, but nobody said anything about it.
            case notReviewed
            /// The render itself failed, so there was nothing to judge.
            case renderFailed
            /// Never rendered in this pass.
            case notRendered
        }

        var id: String
        var title: String
        /// Carried into the report so a reader knows what the reviewer was
        /// asked to look at, without opening the catalogue source.
        var lookFor: String
        var kind: String
        var outcome: Outcome
        /// What the reviewer wrote when rejecting, or the error when the render
        /// failed.
        var note: String?
        var decidedAt: Date?
        /// Path of the artifact inside this report folder, so an entry and its
        /// picture are matched without guessing at a naming rule.
        var file: String?
        var fingerprint: String?
        /// Whether the picture judged here is the same one the previous,
        /// committed verdict was given for. False means the render moved since
        /// it was last approved, which is the interesting case.
        var matchesPreviousApproval: Bool?
    }

    var generatedAt: Date
    var environment: Environment
    var scenarioCount: Int
    var approvedCount: Int
    var rejectedCount: Int
    var notReviewedCount: Int
    var failedCount: Int
    /// Scenarios that never rendered in this pass, which is what makes a
    /// partial pass read as partial.
    var notRenderedCount: Int
    var entries: [Entry]
}

/// Assembles a report folder and zips it.
///
/// The zip is the whole point: a pass ends with a single file in the share
/// sheet, which AirDrops to the author's Mac in one gesture. Handing back a
/// verdict file and then explaining how to dig the renders out of the Files app
/// is the step where a volunteer stops volunteering.
enum VisualReviewReportBuilder {
    /// One scenario, flattened out of its `@MainActor` model object.
    ///
    /// The report copies renders and zips them, which is enough file work to
    /// stutter the interface if it happens on the main thread while somebody is
    /// waiting on a button. Reading the state once, on the main actor, and
    /// handing this across is what lets the rest run off it.
    struct Source {
        var id: String
        var title: String
        var lookFor: String
        var isVideo: Bool
        var artifactURL: URL?
        var fingerprint: String?
        var renderFailure: String?
        var verdict: VisualReviewVerdict?
        var isUnchangedSinceVerdict: Bool
    }

    /// Builds the report for the current state of a pass and returns the zip.
    ///
    /// - Parameter items: every scenario in the catalogue, rendered or not. The
    ///   ones that were not rendered are in the report on purpose: a partial
    ///   pass has to read as partial rather than as a clean sheet.
    @MainActor
    static func makeReport(for items: [VisualReviewItem]) async throws -> URL {
        let sources = items.map { item -> Source in
            var failure: String?
            if case let .failed(message) = item.state {
                failure = message
            }
            return Source(id: item.id,
                          title: item.scenario.title,
                          lookFor: item.scenario.lookFor,
                          isVideo: item.scenario.isVideo,
                          artifactURL: item.artifact?.url,
                          fingerprint: item.artifact?.fingerprint,
                          renderFailure: failure,
                          verdict: item.verdict,
                          isUnchangedSinceVerdict: item.isUnchangedSinceVerdict)
        }
        let environment = currentEnvironment()
        return try await Task.detached {
            try write(sources, environment: environment)
        }.value
    }

    private static func write(_ sources: [Source],
                              environment: VisualReviewReport.Environment) throws -> URL {
        let now = Date()
        let folderName = "ImmersiveMapReview-\(environment.machine)-\(stamp(now))"
            .replacingOccurrences(of: " ", with: "-")
        let root = VisualReviewPaths.reportsDirectory
        // A previous report in the same place would otherwise leave its renders
        // behind and ship them inside this one. Only the newest is kept: it is
        // a copy of state that lives elsewhere, and a phone is not the place to
        // accumulate a hundred megabytes per pass.
        try? FileManager.default.removeItem(at: root)
        let folder = root.appending(path: folderName)
        let renders = folder.appending(path: "Renders")
        try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true)

        var entries: [VisualReviewReport.Entry] = []
        for source in sources {
            var entry = VisualReviewReport.Entry(id: source.id,
                                                 title: source.title,
                                                 lookFor: source.lookFor,
                                                 kind: source.isVideo ? "video" : "still",
                                                 outcome: .notRendered)

            if let failure = source.renderFailure {
                entry.outcome = .renderFailed
                entry.note = failure
            }

            if let artifactURL = source.artifactURL {
                let name = artifactURL.lastPathComponent
                let destination = renders.appending(path: name)
                // A copy that fails leaves the entry without a file rather than
                // aborting the report: a reviewer who has spent the afternoon
                // on this gets the judgements out even if one render cannot be
                // read back off disk.
                if (try? FileManager.default.copyItem(at: artifactURL, to: destination)) != nil {
                    entry.file = "Renders/\(name)"
                }
                entry.fingerprint = source.fingerprint
                entry.outcome = .notReviewed
            }

            if let verdict = source.verdict, let fingerprint = source.fingerprint,
               verdict.fingerprint == fingerprint {
                // Only a verdict given for the picture in this folder counts as
                // a judgement of it. An older verdict, made about a render that
                // has since changed, describes a picture nobody in this pass
                // saw, and reporting it as this pass's answer would be a lie
                // the fingerprint exists to prevent.
                entry.outcome = verdict.ruling == .ok ? .approved : .rejected
                entry.note = verdict.note.isEmpty ? nil : verdict.note
                entry.decidedAt = verdict.decidedAt
            }
            entry.matchesPreviousApproval = source.artifactURL == nil ? nil : source.isUnchangedSinceVerdict
            entries.append(entry)
        }

        let report = VisualReviewReport(
            generatedAt: now,
            environment: environment,
            scenarioCount: entries.count,
            approvedCount: entries.filter { $0.outcome == .approved }.count,
            rejectedCount: entries.filter { $0.outcome == .rejected }.count,
            notReviewedCount: entries.filter { $0.outcome == .notReviewed }.count,
            failedCount: entries.filter { $0.outcome == .renderFailed }.count,
            notRenderedCount: entries.filter { $0.outcome == .notRendered }.count,
            entries: entries)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: folder.appending(path: "report.json"), options: .atomic)
        try readMe(for: report).write(to: folder.appending(path: "README.txt"),
                                      atomically: true,
                                      encoding: .utf8)

        // The verdict file goes in as it stands, not as a copy translated out
        // of the report. It is the format the checkout keeps, so a pass made on
        // someone else's phone can be dropped straight into `Tools/VisualReview`
        // instead of being retyped from the report by hand.
        let verdicts = VisualReviewPaths.verdictsURL
        if FileManager.default.fileExists(atPath: verdicts.path) {
            try? FileManager.default.copyItem(
                at: verdicts,
                to: folder.appending(path: VisualReviewPaths.verdictsFileName))
        }

        return try zip(folder)
    }

    // MARK: - Environment

    @MainActor
    static func currentEnvironment() -> VisualReviewReport.Environment {
        let bundle = Bundle.main.infoDictionary
        let version = [bundle?["CFBundleShortVersionString"] as? String,
                       (bundle?["CFBundleVersion"] as? String).map { "(\($0))" }]
            .compactMap { $0 }
            .joined(separator: " ")
        #if canImport(UIKit)
        let systemName = UIDevice.current.systemName
        let systemVersion = UIDevice.current.systemVersion
        #else
        let systemName = "macOS"
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        return VisualReviewReport.Environment(
            machine: machineIdentifier(),
            systemName: systemName,
            systemVersion: systemVersion,
            gpu: MTLCreateSystemDefaultDevice()?.name,
            commit: VisualReviewPaths.currentCommit(),
            appVersion: version.isEmpty ? nil : version)
    }

    /// The model identifier of the machine, not the architecture.
    ///
    /// On iOS `uname` answers with the model (`iPhone17,1`). On macOS it
    /// answers `arm64`, which says nothing about which Mac rendered the
    /// pictures, so the model comes from `hw.model` there.
    private static func machineIdentifier() -> String {
        #if os(macOS)
        var size = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 {
            var value = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &value, &size, nil, 0) == 0 {
                let model = String(cString: value)
                if model.isEmpty == false {
                    return model
                }
            }
        }
        #endif
        var info = utsname()
        uname(&info)
        let machine = info.machine
        let identifier = withUnsafeBytes(of: machine) { buffer in
            buffer.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
        }
        return identifier.isEmpty ? "unknown" : identifier
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }

    /// A plain-text summary beside the JSON.
    ///
    /// The JSON is what gets read against the committed verdicts; this is what
    /// gets read by whoever opens the zip first, including the person who made
    /// it and wants to check they did not send an empty pass.
    private static func readMe(for report: VisualReviewReport) -> String {
        var lines = [
            "ImmersiveMap visual review",
            "",
            "Device:  \(report.environment.machine)"
                + "  \(report.environment.systemName) \(report.environment.systemVersion)",
            "GPU:     \(report.environment.gpu ?? "unknown")",
            "Commit:  \(report.environment.commit ?? "unknown")",
            "Made at: \(ISO8601DateFormatter().string(from: report.generatedAt))",
            "",
            "\(report.approvedCount) approved, \(report.rejectedCount) rejected, "
                + "\(report.notReviewedCount) rendered but not judged, "
                + "\(report.failedCount) failed to render, \(report.notRenderedCount) not rendered, "
                + "out of \(report.scenarioCount).",
            "",
        ]
        for entry in report.entries {
            var line = "\(symbol(for: entry.outcome)) \(entry.title)"
            if let note = entry.note {
                line += ": \(note)"
            }
            lines.append(line)
        }
        lines.append("")
        lines.append("report.json carries the same thing in full, and Renders/ holds "
            + "every picture these judgements were made about.")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func symbol(for outcome: VisualReviewReport.Entry.Outcome) -> String {
        switch outcome {
        case .approved: return "[ok]     "
        case .rejected: return "[WRONG]  "
        case .notReviewed: return "[?]      "
        case .renderFailed: return "[FAILED] "
        case .notRendered: return "[-]      "
        }
    }

    // MARK: - Zipping

    /// Zips a folder without a third-party archiver.
    ///
    /// `NSFileCoordinator` with `.forUploading` is the system's own way to hand
    /// a folder to something that wants one file, and it is on both platforms.
    /// The archive it produces is temporary and only valid inside the accessor,
    /// so it is copied out before the block returns.
    private static func zip(_ folder: URL) throws -> URL {
        let destination = folder.deletingLastPathComponent()
            .appending(path: folder.lastPathComponent + ".zip")
        try? FileManager.default.removeItem(at: destination)

        final class Outcome {
            var error: Error?
        }
        let outcome = Outcome()
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder,
                                       options: [.forUploading],
                                       error: &coordinationError) { archive in
            do {
                try FileManager.default.copyItem(at: archive, to: destination)
            } catch {
                outcome.error = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let error = outcome.error {
            throw error
        }
        return destination
    }
}
