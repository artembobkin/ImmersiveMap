// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// The pin shape as numbers: where its anchor and picture area land in the
/// quad, and the distance field baked from its path.
final class PinShapeTests: XCTestCase {
    func testBubbleStandsOnItsTailAndCircleOnItsCenter() {
        let bubble = PinShapeMetrics(shape: .bubble)
        XCTAssertEqual(bubble.anchor.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(bubble.anchor.y, 0.0, accuracy: 1e-6,
                       "The built-in bubble's texture reaches the quad's lower edge")
        XCTAssertGreaterThan(bubble.bodyCenter.y, 0.5, "The body sits above the tail")
        XCTAssertEqual(bubble.bodyHalfSize.x, 0.5, accuracy: 1e-6)
        XCTAssertFalse(bubble.isFrameless)

        let tailed = PinShapeMetrics(shape: .roundedRectangle(cornerRadius: 0.2, tail: true))
        XCTAssertEqual(tailed.anchor.y, Float(PinShapeDistanceField.margin), accuracy: 1e-5,
                       "A baked shape is drawn inside the margin of its texture")

        let circle = PinShapeMetrics(shape: .circle)
        XCTAssertEqual(circle.anchor.x, circle.bodyCenter.x, accuracy: 1e-5)
        XCTAssertEqual(circle.anchor.y, circle.bodyCenter.y, accuracy: 1e-5)
    }

    func testPictureFillsTheQuadWithoutMargin() {
        let metrics = PinShapeMetrics(shape: .picture(anchor: CGPoint(x: 0.0, y: 1.0)))
        XCTAssertTrue(metrics.isFrameless)
        XCTAssertEqual(metrics.anchor.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(metrics.anchor.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(metrics.bodyHalfSize.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(metrics.circleRadius, 0.5, accuracy: 1e-6)
    }

    func testCustomPathTakesItsBoundsAsThePictureArea() {
        let path = CGPath(rect: CGRect(x: 0.25, y: 0.0, width: 0.5, height: 0.5), transform: nil)
        let shape = PinShape.path(path)
        XCTAssertEqual(shape.pictureArea, CGRect(x: 0.25, y: 0.0, width: 0.5, height: 0.5))
        XCTAssertEqual(shape.anchor, CGPoint(x: 0.5, y: 1.0))

        let metrics = PinShapeMetrics(shape: shape)
        // The area is the upper half of the square, so its center is above
        // the middle in the quad's own coordinates, where y points up.
        XCTAssertGreaterThan(metrics.bodyCenter.y, 0.5)
        XCTAssertEqual(metrics.bodyHalfSize.x, metrics.bodyHalfSize.y, accuracy: 1e-5)
    }

    func testAnchorMovesTheQuadAndTheBodyOffset() {
        let centered = PinStyle(sizePx: 100.0,
                                outlineWidthPx: 3.0,
                                metrics: PinShapeMetrics(shape: .picture()))
        XCTAssertEqual(centered.quadOriginPx.x, -50.0, accuracy: 1e-4)
        XCTAssertEqual(centered.quadOriginPx.y, -50.0, accuracy: 1e-4)
        XCTAssertEqual(simd_length(centered.bodyCenterOffsetPx), 0.0, accuracy: 1e-4)

        let cornered = PinStyle(sizePx: 100.0,
                                outlineWidthPx: 3.0,
                                metrics: PinShapeMetrics(shape: .picture(anchor: CGPoint(x: 0.0, y: 1.0))))
        XCTAssertEqual(cornered.quadOriginPx.x, 0.0, accuracy: 1e-4)
        XCTAssertEqual(cornered.bodyCenterOffsetPx.x, 50.0, accuracy: 1e-4)
        XCTAssertEqual(cornered.bodyCenterOffsetPx.y, 50.0, accuracy: 1e-4)
    }

    func testDistanceFieldOfASquareIsSignedAndMeasuredFromItsEdge() {
        // A square of 8 samples in a grid of 16: samples 4 to 11 are inside.
        let side = 16
        var inside = [Bool](repeating: false, count: side * side)
        for y in 4..<12 {
            for x in 4..<12 {
                inside[y * side + x] = true
            }
        }
        let distances = PinShapeDistanceField.signedDistances(inside: inside, side: side)

        // The edge runs half a sample outside the first inside sample.
        XCTAssertEqual(distances[8 * side + 4], -0.5, accuracy: 1e-4)
        XCTAssertEqual(distances[8 * side + 3], 0.5, accuracy: 1e-4)
        XCTAssertEqual(distances[8 * side + 0], 3.5, accuracy: 1e-4)
        // The deepest samples are four samples from the nearest outside one.
        XCTAssertEqual(distances[7 * side + 7], -3.5, accuracy: 1e-4)
        // A corner sample outside is measured along the diagonal.
        XCTAssertEqual(distances[3 * side + 3], Float(2.0).squareRoot() - 0.5, accuracy: 1e-4)
    }

    func testBakedCircleIsInsideAtItsCenterAndOutsideInTheCorner() {
        let field = PinShapeDistanceField.encodedField(paths: [
            CGPath(ellipseIn: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0), transform: nil)
        ])
        let side = PinShapeDistanceField.textureSize
        XCTAssertEqual(field.count, side * side)

        let edge = PinShapeDistanceField.encode(distanceTexels: 0.0)
        XCTAssertGreaterThan(field[(side / 2) * side + side / 2], edge)
        XCTAssertLessThan(field[0], edge)

        // The circle's radius is half the square inside the margin, and the
        // center is that far from the edge.
        let radiusTexels = Float(side) * Float(0.5 - PinShapeDistanceField.margin)
        let expected = PinShapeDistanceField.encode(distanceTexels: -radiusTexels)
        let center = field[(side / 2) * side + side / 2]
        XCTAssertLessThan(abs(Int(center) - Int(expected)), 400,
                          "The center is about a radius inside, within a texel and a half")
    }

    func testMaskIsInsideWhereItIsLightAndOpaque() throws {
        // A mask of 64 pixels: white on the left half, transparent on the right.
        let side = 64
        let context = try XCTUnwrap(CGContext(data: nil,
                                              width: side,
                                              height: side,
                                              bitsPerComponent: 8,
                                              bytesPerRow: side * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: side / 2, height: side))
        let mask = try XCTUnwrap(context.makeImage())

        let grid = 128
        let inside = PinShapeDistanceField.coverage(mask: mask, side: grid)
        XCTAssertTrue(inside[(grid / 2) * grid + grid / 4])
        XCTAssertFalse(inside[(grid / 2) * grid + 3 * grid / 4])
        XCTAssertFalse(inside[0], "The margin round the mask is outside the shape")

        let shape = PinShape.mask(mask)
        XCTAssertEqual(shape.pictureArea, CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0))
        XCTAssertEqual(shape.anchor, CGPoint(x: 0.5, y: 1.0))
    }

    func testEncodingPutsTheEdgeInTheMiddleAndClamps() {
        XCTAssertEqual(PinShapeDistanceField.encode(distanceTexels: 0.0), 32768)
        XCTAssertEqual(PinShapeDistanceField.encode(distanceTexels: 1.0e6), 0)
        XCTAssertEqual(PinShapeDistanceField.encode(distanceTexels: -1.0e6), 65535)
    }
}
