// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreGraphics
import ImageIO
import ImmersiveMap
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Verdicts

/// What a person decided about one scenario, and what they were looking at
/// when they decided it.
struct VisualReviewVerdict: Codable, Equatable {
    enum Ruling: String, Codable {
        case ok
        case notOk
    }

    var ruling: Ruling
    /// Required for `notOk`, and the reason the file is worth committing: six
    /// months later "the shadow under the tower is inverted" is the only part
    /// anyone remembers.
    var note: String
    /// When the ruling was made.
    var decidedAt: Date
    /// Fingerprint of the artifact that was actually looked at. The next run
    /// compares against this to tell an unchanged picture from a new one.
    var fingerprint: String
    /// Repository commit the artifact was rendered from, when it could be
    /// determined. Diagnostic only.
    var commit: String?
}

/// The verdict file: one entry per scenario, keyed by scenario id.
///
/// Committed to the repository on purpose. A verdict is a statement about the
/// renderer at a point in its history, and it is worth having in the same
/// place as the code it judged.
struct VisualReviewVerdictStore {
    private(set) var verdicts: [String: VisualReviewVerdict]
    let url: URL

    init(url: URL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let decoded = try? decoder.decode([String: VisualReviewVerdict].self, from: data) {
            self.verdicts = decoded
        } else {
            self.verdicts = [:]
        }
    }

    subscript(scenarioID: String) -> VisualReviewVerdict? {
        verdicts[scenarioID]
    }

    mutating func record(_ verdict: VisualReviewVerdict, for scenarioID: String) throws {
        verdicts[scenarioID] = verdict
        try save()
    }

    mutating func clear(_ scenarioID: String) throws {
        verdicts.removeValue(forKey: scenarioID)
        try save()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(verdicts).write(to: url, options: .atomic)
    }
}

// MARK: - Fingerprinting

/// A coarse fingerprint of a rendered picture, used to answer one question:
/// has this scene changed since it was approved?
///
/// Deliberately blunt. Rendering is not bit-identical across GPU models,
/// driver versions or macOS updates, so an exact hash would report every
/// scenario as changed the first time you review on a different machine, and
/// the tool would be useless exactly when you need it. The image is reduced to
/// a 16x16 thumbnail and each channel is quantized to 4 bits, which survives
/// that noise while still catching anything a person would notice: a colour
/// shift, a moved shadow, geometry that stopped drawing.
///
/// It is not a correctness check. It never decides that a picture is good, only
/// that it is the same picture.
enum VisualReviewFingerprint {
    private static let side = 16

    static func of(_ image: CGImage) -> String {
        let count = side * side * 4
        var pixels = [UInt8](repeating: 0, count: count)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: side,
                                          height: side,
                                          bitsPerComponent: 8,
                                          bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }

        var digest = ""
        digest.reserveCapacity(count)
        for value in pixels {
            // One hex digit per channel: the top 4 bits, so a difference has
            // to be worth about 16 levels out of 255 before it registers.
            digest.append(String(value >> 4, radix: 16))
        }
        return digest
    }

    /// Fingerprint of an image already written to disk, for renders adopted
    /// from an earlier session.
    static func ofImageFile(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return of(image)
    }

    /// Fingerprint of a movie: several frames spread across its length, so a
    /// change in the middle of a flight counts even when the first and last
    /// frames are identical.
    static func ofVideo(at url: URL, sampleCount: Int = 6) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else {
            return nil
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var digests: [String] = []
        for index in 0 ..< sampleCount {
            let fraction = Double(index) / Double(max(1, sampleCount - 1))
            let time = CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else {
                continue
            }
            digests.append(of(image))
        }
        return digests.isEmpty ? nil : digests.joined(separator: ":")
    }
}

// MARK: - Rendering

/// Where the rendered artifacts live and what the runner produced.
struct VisualReviewArtifact: Identifiable {
    let scenarioID: String
    let url: URL
    let fingerprint: String

    var id: String { scenarioID }
}

/// Renders the catalogue into a folder.
///
/// Stills go through ``ImmersiveMapStillRecorder`` and are written as PNG,
/// which is lossless: a reviewer judging the picture must never be looking at
/// a compression artifact and wondering whether the renderer made it.
@MainActor
final class VisualReviewRenderer {
    /// Stills are rendered at this size. Big enough to judge label legibility
    /// and building edges, small enough that a full pass is quick.
    static let stillSize = (width: 1600, height: 1000)

    private let stillRecorder = ImmersiveMapStillRecorder()

    /// Renders one still and writes it as a PNG into `directory`.
    func renderStill(_ scenario: VisualReviewScenario,
                     camera: ImmersiveMapCameraPosition,
                     into directory: URL) async throws -> VisualReviewArtifact {
        let configuration = ImmersiveMapStillConfiguration(
            width: Self.stillSize.width,
            height: Self.stillSize.height,
            pixelsPerPoint: 2,
            // Generous on purpose: an unfinished tile is the one thing that
            // would make a reviewer reject a frame the renderer got right.
            tileReadinessTimeout: 30,
            sceneDate: VisualReviewCatalogue.sceneDate)

        let image = try await stillRecorder.capture(settings: scenario.settings,
                                                    camera: camera,
                                                    routes: scenario.routes,
                                                    configuration: configuration)
        let url = directory.appending(path: "\(scenario.id).png")
        try write(image, to: url)
        return VisualReviewArtifact(scenarioID: scenario.id,
                                    url: url,
                                    fingerprint: VisualReviewFingerprint.of(image))
    }

    /// Movie output: 1280x720 at 30 fps is enough to judge motion, popping and
    /// fades without making a pre-release pass take an afternoon.
    static let videoConfiguration = ImmersiveMapVideoExportConfiguration(
        width: 1280,
        height: 720,
        framesPerSecond: 30,
        tileReadinessTimeout: 30,
        sceneDate: VisualReviewCatalogue.sceneDate)

    /// Exports one video through a recorder the caller has already attached to
    /// an on-screen map configured for this scenario.
    ///
    /// The video recorder only works attached to a live view, so unlike stills
    /// a clip cannot be rendered from nothing: the app puts the map on screen
    /// for the scenario being rendered and hands the attached recorder here.
    func renderVideo(_ scenario: VisualReviewScenario,
                     establish: ImmersiveMapCameraPosition,
                     shots: [ImmersiveMapCameraTourShot],
                     recorder: ImmersiveMapTourVideoRecorder,
                     into directory: URL) async throws -> VisualReviewArtifact {
        let url = directory.appending(path: "\(scenario.id).mov")

        // The recorder binds to the map on a SwiftUI commit that may land
        // after this call: retry the not-attached error rather than sleeping a
        // fixed delay and hoping.
        var attachAttemptsLeft = 50
        while true {
            do {
                try await recorder.export(shots: shots,
                                          establish: establish,
                                          configuration: Self.videoConfiguration,
                                          to: url)
                break
            } catch ImmersiveMapVideoExportError.notAttached where attachAttemptsLeft > 0 {
                attachAttemptsLeft -= 1
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        let fingerprint = await VisualReviewFingerprint.ofVideo(at: url) ?? ""
        return VisualReviewArtifact(scenarioID: scenario.id, url: url, fingerprint: fingerprint)
    }

    private func write(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.png.identifier as CFString,
                                                                1,
                                                                nil) else {
            throw VisualReviewError.couldNotWriteImage(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw VisualReviewError.couldNotWriteImage(url)
        }
    }
}

enum VisualReviewError: Error, CustomStringConvertible {
    case couldNotWriteImage(URL)

    var description: String {
        switch self {
        case let .couldNotWriteImage(url):
            return "Could not write the rendered image to \(url.path)"
        }
    }
}

// MARK: - Locating the repository

/// Finds the checkout the app was built from, so renders and verdicts land
/// next to the code they describe rather than in a container nobody looks in.
enum VisualReviewPaths {
    /// Walks up from this source file's location at build time. The app is a
    /// development tool built from the repository it inspects, so the path is
    /// known and stable; falling back to the user's Documents folder keeps a
    /// copied binary from crashing.
    static var repositoryRoot: URL {
        // .../Tools/VisualReview/ImmersiveMapVisualReview/VisualReviewRenderer.swift
        let source = URL(fileURLWithPath: #filePath)
        let candidate = source
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: candidate.appending(path: "Package.swift").path) {
            return candidate
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "ImmersiveMapVisualReview")
    }

    /// Gitignored: renders are large, machine specific, and regenerated on
    /// demand.
    static var outputDirectory: URL {
        repositoryRoot.appending(path: "Tools/VisualReview/Output")
    }

    /// Committed: the verdicts are the record of what a person approved.
    static var verdictsURL: URL {
        repositoryRoot.appending(path: "Tools/VisualReview/verdicts.json")
    }

    /// Short commit hash of the checkout, for the record in a verdict.
    static func currentCommit() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repositoryRoot.path, "rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
