// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The labels a frame works on (`LabelActiveSpans`): the head of each
/// tile's run its zoom shows, and the labels behind it still fading out.
final class LabelActiveSpansTests: XCTestCase {
    /// Two tiles of labels ordered by their zoom: 0, 14, 16, 17 and 15, 18.
    private let inputs = [0, 14, 16, 17, 15, 18].enumerated().map { index, zoom in
        BaseLabelPresentationInput(labelKey: UInt64(index), minCameraZoom: Float(zoom))
    }
    private let runs = [0..<4, 4..<6]

    private func resolve(_ spans: inout LabelActiveSpans, zoom: Float, alphas: [Float]) {
        inputs.withUnsafeBufferPointer { inputs in
            alphas.withUnsafeBufferPointer { alphas in
                spans.resolve(inputs: inputs, alphas: alphas, cameraZoom: zoom)
            }
        }
    }

    private func fade(_ spans: inout LabelActiveSpans, alphas: [Float], targets: [Bool]) {
        alphas.withUnsafeBufferPointer { alphas in
            targets.withUnsafeBufferPointer { targets in
                spans.updateLitEnds(alphas: alphas, targets: targets)
            }
        }
    }

    func testEachRunIsWorkedOnUpToTheLabelsItsZoomShows() {
        var spans = LabelActiveSpans()
        spans.rebind(runs: runs)
        let dark = [Float](repeating: 0, count: 6)
        resolve(&spans, zoom: 16, alphas: dark)

        XCTAssertEqual(spans.spans, [0..<3, 4..<5])
        XCTAssertEqual(spans.count, 4)
    }

    func testARunWithNothingAtTheZoomIsLeftOut() {
        var spans = LabelActiveSpans()
        spans.rebind(runs: [0..<4, 4..<6])
        resolve(&spans, zoom: 14.5, alphas: [Float](repeating: 0, count: 6))

        XCTAssertEqual(spans.spans, [0..<2])
    }

    /// Zooming out, the labels past the new zoom are worked on while they
    /// fade out, and left once they are dark.
    func testALabelPastTheZoomIsWorkedOnUntilItHasFadedOut() {
        var spans = LabelActiveSpans()
        spans.rebind(runs: runs)
        resolve(&spans, zoom: 17, alphas: [Float](repeating: 0, count: 6))
        XCTAssertEqual(spans.spans, [0..<4, 4..<5])
        fade(&spans, alphas: [1, 1, 1, 1, 1, 0], targets: [true, true, true, true, true, false])

        resolve(&spans, zoom: 15, alphas: [1, 1, 1, 1, 1, 0])
        XCTAssertEqual(spans.spans, [0..<4, 4..<5], "The labels of 16 and 17 still fade out")

        fade(&spans, alphas: [1, 1, 0.5, 0, 1, 0], targets: [true, true, false, false, true, false])
        resolve(&spans, zoom: 15, alphas: [1, 1, 0.5, 0, 1, 0])
        XCTAssertEqual(spans.spans, [0..<3, 4..<5], "The label of 17 is dark: left out")

        fade(&spans, alphas: [1, 1, 0, 0, 1, 0], targets: [true, true, false, false, true, false])
        resolve(&spans, zoom: 15, alphas: [1, 1, 0, 0, 1, 0])
        XCTAssertEqual(spans.spans, [0..<2, 4..<5])
    }

    /// A run that survived a change of the set carries its fades: the
    /// first resolve finds its lit labels past the zoom in the alphas.
    func testARebindFindsTheLitLabelsTheRunsCarried() {
        var spans = LabelActiveSpans()
        spans.rebind(runs: runs)
        resolve(&spans, zoom: 14, alphas: [1, 1, 0, 0.4, 0, 0])

        XCTAssertEqual(spans.spans, [0..<4], "The label of 17 still lit, the label of 16 before it with it")

        resolve(&spans, zoom: 14, alphas: [1, 1, 0, 0.4, 0, 0])
        XCTAssertEqual(spans.spans, [0..<4], "Found once, kept until the fades say otherwise")
    }
}
