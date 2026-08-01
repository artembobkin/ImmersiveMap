// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreGraphics
import Foundation

/// Inspects an exported video file for test assertions.
///
/// `AVAsset.loadTracks` returns non-Sendable `AVAssetTrack`s, which stricter
/// Swift 6 toolchains refuse to send into a `@MainActor` test. The probe keeps
/// all track objects inside a nonisolated context and hands only Sendable
/// values back to the tests.
enum ExportedVideoProbe {
    struct Summary: Sendable {
        let durationSeconds: Double
        let videoTrackCount: Int
        let naturalSize: CGSize
        let codec: FourCharCode?
        let colorPrimaries: String?
    }

    static func summary(url: URL) async throws -> Summary {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        var naturalSize: CGSize = .zero
        var codec: FourCharCode?
        var colorPrimaries: String?
        if let track = tracks.first {
            naturalSize = try await track.load(.naturalSize)
            if let formatDescription = try await track.load(.formatDescriptions).first {
                codec = CMFormatDescriptionGetMediaSubType(formatDescription)
                colorPrimaries = CMFormatDescriptionGetExtension(
                    formatDescription,
                    extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
                ) as? String
            }
        }
        return Summary(durationSeconds: duration.seconds,
                       videoTrackCount: tracks.count,
                       naturalSize: naturalSize,
                       codec: codec,
                       colorPrimaries: colorPrimaries)
    }
}
