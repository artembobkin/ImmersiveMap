// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import simd

/// The shape of the frame every pin of a map is drawn in: the outline, the
/// fill under the picture and the cut of the picture itself all follow it.
/// One shape serves all the pins of a map, set with
/// `ImmersiveMapView.pinSettings(shape:)`.
///
/// A shape is described in a unit square whose origin is the top left corner
/// and whose y axis points down, as in SwiftUI. Besides the built-in ones it
/// can be a picture of the shape (`mask`) or a path (`path`): the engine
/// turns either into a distance field once, when the map is created, so no
/// distance texture has to be prepared by hand.
///
/// A pin pushed off its place by its neighbours still turns into a circle
/// with a beam, whatever its shape is. The circle is the largest one that
/// fits the shape's picture area.
public struct PinShape: Equatable, Sendable {
    enum Outline: Equatable, @unchecked Sendable {
        /// The engine's own bubble, from the distance field in its resources.
        case bubble
        /// The parts of the shape, filled one over another.
        case paths([CGPath])
        /// A picture of the shape: light and opaque where the pin is.
        case mask(CGImage)
        /// No frame: the picture's own alpha is the shape.
        case picture
    }

    let outline: Outline
    /// The point of the shape that stands on the pin's coordinate.
    let anchor: CGPoint
    /// The rectangle the picture is laid into.
    let pictureArea: CGRect

    /// The height of a built-in shape's tail, as a part of the pin's size.
    static let tailHeight: CGFloat = 0.06
    /// Half the width of the tail where it leaves the body.
    static let tailHalfWidth: CGFloat = 0.09
    /// How deep the tail's wedge reaches into the body, so that it joins a
    /// body with round corners without a gap.
    static let tailDepth: CGFloat = 0.1

    /// The height of the built-in bubble's tail, as a part of the pin's
    /// size, when the bubble's own resource does not say.
    static let bubbleTailHeight: CGFloat = 0.046875

    /// The engine's own shape: a rounded square with a small tail that
    /// points at the pin's place. The default.
    public static let bubble = PinShape(outline: .bubble,
                                        anchor: CGPoint(x: 0.5, y: 1.0),
                                        pictureArea: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0 - bubbleTailHeight))

    /// A circle centered on the pin's place.
    public static let circle = roundedRectangle(cornerRadius: 0.5, tail: false)

    /// A rounded rectangle.
    ///
    /// - Parameters:
    ///   - cornerRadius: The radius of the corners as a part of the pin's
    ///     size, from 0 (a square) to 0.5 (a circle).
    ///   - tail: Whether the shape has a tail under it. With a tail the tip
    ///     of the tail stands on the pin's coordinate, without one the
    ///     center of the shape does.
    public static func roundedRectangle(cornerRadius: CGFloat, tail: Bool = false) -> PinShape {
        let bodyHeight = tail ? 1.0 - tailHeight : 1.0
        let body = CGRect(x: 0.0, y: 0.0, width: 1.0, height: bodyHeight)
        let radius = min(max(cornerRadius, 0.0), 0.5) * min(body.width, body.height)
        var parts = [CGPath(roundedRect: body,
                            cornerWidth: radius,
                            cornerHeight: radius,
                            transform: nil)]
        guard tail else {
            return PinShape(outline: .paths(parts),
                            anchor: CGPoint(x: 0.5, y: 0.5),
                            pictureArea: body)
        }

        // A wedge from inside the body down to the tip. It is as wide as
        // `tailHalfWidth` where it crosses the body's lower edge.
        let wedgeHalfWidth = tailHalfWidth * (tailHeight + tailDepth) / tailHeight
        let wedge = CGMutablePath()
        wedge.move(to: CGPoint(x: 0.5 - wedgeHalfWidth, y: bodyHeight - tailDepth))
        wedge.addLine(to: CGPoint(x: 0.5 + wedgeHalfWidth, y: bodyHeight - tailDepth))
        wedge.addLine(to: CGPoint(x: 0.5, y: 1.0))
        wedge.closeSubpath()
        parts.append(wedge)
        return PinShape(outline: .paths(parts),
                        anchor: CGPoint(x: 0.5, y: 1.0),
                        pictureArea: body)
    }

    /// A shape of the app's own.
    ///
    /// - Parameters:
    ///   - path: A closed path in a unit square, origin in the top left
    ///     corner, y down. What lies outside the square is cut off.
    ///   - anchor: The point of the square that stands on the pin's
    ///     coordinate, the bottom center by default. For a shape with a
    ///     pointer it is the pointer's tip.
    ///   - pictureArea: The rectangle of the square the picture is laid
    ///     into. The path's bounding box by default. Give it when the shape
    ///     has a part the picture should not reach, a pointer for example.
    public static func path(_ path: CGPath,
                            anchor: CGPoint = CGPoint(x: 0.5, y: 1.0),
                            pictureArea: CGRect? = nil) -> PinShape {
        let unit = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
        let bounds = path.boundingBoxOfPath
        var area = (pictureArea ?? bounds).intersection(unit)
        if area.isNull || area.width <= 0.0 || area.height <= 0.0 {
            area = unit
        }
        return PinShape(outline: .paths([path]),
                        anchor: CGPoint(x: min(max(anchor.x, 0.0), 1.0),
                                        y: min(max(anchor.y, 0.0), 1.0)),
                        pictureArea: area)
    }

    /// A shape taken from a picture of it, a PNG drawn in any editor: the
    /// pin is where the picture is light and opaque, and is not where it is
    /// black or transparent. The picture is stretched to a square, so draw
    /// it square. The map turns it into the frame once, when it is created.
    ///
    /// - Parameters:
    ///   - mask: The picture of the shape. 256 pixels a side are enough.
    ///   - anchor: The point of the picture that stands on the pin's
    ///     coordinate, in a unit square with the origin in the top left
    ///     corner and y down. The bottom center by default.
    ///   - pictureArea: The rectangle of that square the pin's picture is
    ///     laid into. The whole square by default. Give it when the shape
    ///     has a part the picture should not reach, a pointer for example.
    public static func mask(_ mask: CGImage,
                            anchor: CGPoint = CGPoint(x: 0.5, y: 1.0),
                            pictureArea: CGRect? = nil) -> PinShape {
        let unit = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
        var area = (pictureArea ?? unit).intersection(unit)
        if area.isNull || area.width <= 0.0 || area.height <= 0.0 {
            area = unit
        }
        return PinShape(outline: .mask(mask),
                        anchor: CGPoint(x: min(max(anchor.x, 0.0), 1.0),
                                        y: min(max(anchor.y, 0.0), 1.0)),
                        pictureArea: area)
    }

    /// No frame: the pin is its picture alone, cut by the picture's own
    /// alpha, with no outline and no fill.
    ///
    /// - Parameter anchor: The point of the picture that stands on the pin's
    ///   coordinate, in a unit square with the origin in the top left
    ///   corner. The center by default.
    public static func picture(anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> PinShape {
        PinShape(outline: .picture,
                 anchor: CGPoint(x: min(max(anchor.x, 0.0), 1.0),
                                 y: min(max(anchor.y, 0.0), 1.0)),
                 pictureArea: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0))
    }

    var isFrameless: Bool {
        outline == .picture
    }

    /// Whether the engine bakes this shape's distance field itself.
    var isBaked: Bool {
        switch outline {
        case .paths, .mask: true
        case .bubble, .picture: false
        }
    }
}

/// A pin shape as the drawing reads it: fractions of the pin's quad, with the
/// origin in the bottom left corner and y up, as the quad's own coordinates.
struct PinShapeMetrics: Equatable {
    /// The point of the quad that stands on the pin's coordinate.
    let anchor: SIMD2<Float>
    /// The center of the picture area, which is also the center of the
    /// circle a pushed pin turns into.
    let bodyCenter: SIMD2<Float>
    /// Half the picture area's width and height.
    let bodyHalfSize: SIMD2<Float>
    let isFrameless: Bool

    /// The radius of the circle a pushed pin turns into.
    var circleRadius: Float {
        min(bodyHalfSize.x, bodyHalfSize.y)
    }

    /// - Parameter bubbleTailHeight: The height of the built-in bubble's
    ///   tail as its resource states it, which places the bubble's body.
    init(shape: PinShape, bubbleTailHeight: Float = Float(PinShape.bubbleTailHeight)) {
        // A baked shape is drawn inside a margin of its texture, so that its
        // soft edge is not cut by the quad. The built-in bubble's texture
        // has its own, and a bare picture fills the quad.
        let margin = shape.isBaked ? Float(PinShapeDistanceField.margin) : 0.0
        let scale = 1.0 - 2.0 * margin
        var pictureArea = shape.pictureArea
        if shape.outline == .bubble {
            pictureArea.size.height = CGFloat(1.0 - bubbleTailHeight)
        }
        func placed(_ point: CGPoint) -> SIMD2<Float> {
            SIMD2<Float>(margin + Float(point.x) * scale,
                         1.0 - (margin + Float(point.y) * scale))
        }
        self.anchor = placed(shape.anchor)
        self.bodyCenter = placed(CGPoint(x: pictureArea.midX, y: pictureArea.midY))
        self.bodyHalfSize = SIMD2<Float>(Float(pictureArea.width),
                                         Float(pictureArea.height)) * (0.5 * scale)
        self.isFrameless = shape.isFrameless
    }
}
