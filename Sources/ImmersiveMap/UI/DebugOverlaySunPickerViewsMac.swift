// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit
import simd

/// The sky from above (`DebugOverlaySunDial`): a disc that turns with the
/// camera, the view's direction up, with the sun on it to drag. The rim is
/// the horizon, the rings 30° and 60° of elevation, the centre the zenith.
/// The compass letters turn with the view, and a line from the centre to
/// the sun is the light's way, its shadow falling the other way.
final class DebugOverlaySunDialView: NSView {
    var azimuthDegrees: Double = 0 { didSet { needsDisplay = true } }
    var elevationDegrees: Double = 45 { didSet { needsDisplay = true } }
    var viewAzimuthDegrees: Double = 0 { didSet { if viewAzimuthDegrees != oldValue { needsDisplay = true } } }
    var elevationRange: ClosedRange<Double> = 0 ... 90
    /// The sun dragged to an azimuth and an elevation, in degrees.
    var onChange: ((Double, Double) -> Void)?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    private var discRect: CGRect {
        let side = min(bounds.width, bounds.height) - Self.margin * 2
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    override func draw(_: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let disc = discRect
        let centre = CGPoint(x: disc.midX, y: disc.midY)
        let radius = disc.width / 2

        NSColor(calibratedRed: 0.16, green: 0.24, blue: 0.36, alpha: 0.9).setFill()
        NSBezierPath(ovalIn: disc).fill()
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let rim = NSBezierPath(ovalIn: disc)
        rim.lineWidth = 1.5
        rim.stroke()
        for elevation in [30.0, 60.0] {
            let ringRadius = radius * (90 - elevation) / 90
            let ring = NSBezierPath(ovalIn: CGRect(x: centre.x - ringRadius, y: centre.y - ringRadius,
                                                   width: ringRadius * 2, height: ringRadius * 2))
            ring.setLineDash([3, 3], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.25).setStroke()
            ring.stroke()
        }

        // The view: up the disc, an arrow at the top of the rim.
        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: centre.x, y: disc.maxY + Self.margin * 0.85))
        arrow.line(to: CGPoint(x: centre.x - 5, y: disc.maxY + 1))
        arrow.line(to: CGPoint(x: centre.x + 5, y: disc.maxY + 1))
        arrow.close()
        NSColor.white.withAlphaComponent(0.9).setFill()
        arrow.fill()

        // The compass, turned with the view.
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        for (letter, azimuth) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] {
            let unit = DebugOverlaySunDial.point(azimuthDegrees: azimuth, elevationDegrees: 0,
                                                 viewAzimuthDegrees: viewAzimuthDegrees)
            let at = CGPoint(x: centre.x + CGFloat(unit.x) * (radius - 9), y: centre.y + CGFloat(unit.y) * (radius - 9))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: letter == "N" ? NSColor.systemRed : NSColor.white.withAlphaComponent(0.75)
            ]
            let size = (letter as NSString).size(withAttributes: attributes)
            (letter as NSString).draw(at: CGPoint(x: at.x - size.width / 2, y: at.y - size.height / 2), withAttributes: attributes)
        }

        // The sun and the light's way to the ground at the centre.
        let unit = DebugOverlaySunDial.point(azimuthDegrees: azimuthDegrees, elevationDegrees: elevationDegrees,
                                             viewAzimuthDegrees: viewAzimuthDegrees)
        let sun = CGPoint(x: centre.x + CGFloat(unit.x) * radius, y: centre.y + CGFloat(unit.y) * radius)
        let ray = NSBezierPath()
        ray.move(to: sun)
        ray.line(to: centre)
        ray.lineWidth = 1.5
        NSColor.systemYellow.withAlphaComponent(0.6).setStroke()
        ray.stroke()
        NSColor.white.withAlphaComponent(0.8).setFill()
        NSBezierPath(ovalIn: CGRect(x: centre.x - 2, y: centre.y - 2, width: 4, height: 4)).fill()
        Self.drawSun(at: sun)
    }

    override func mouseDown(with event: NSEvent) {
        drag(to: event)
    }

    override func mouseDragged(with event: NSEvent) {
        drag(to: event)
    }

    private func drag(to event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let disc = discRect
        guard disc.width > 0 else { return }
        let point = SIMD2<Double>(Double((location.x - disc.midX) / (disc.width / 2)),
                                  Double((location.y - disc.midY) / (disc.height / 2)))
        let angles = DebugOverlaySunDial.angles(point: point,
                                                viewAzimuthDegrees: viewAzimuthDegrees,
                                                azimuthDegrees: azimuthDegrees,
                                                elevationRange: elevationRange)
        azimuthDegrees = angles.azimuthDegrees
        elevationDegrees = angles.elevationDegrees
        onChange?(angles.azimuthDegrees, angles.elevationDegrees)
    }

    /// Room around the disc for the view's arrow.
    static let margin: CGFloat = 12

    static func drawSun(at point: CGPoint) {
        let radius: CGFloat = 7
        NSColor.systemYellow.setFill()
        NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        let outline = NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        outline.lineWidth = 1
        outline.stroke()
    }
}

/// The sky from the side (`DebugOverlaySunDial.elevation(sidePoint:)`): a
/// quarter circle over the ground, the horizon to the right and the zenith
/// straight up, with the sun on it to drag and its light's way down to the
/// ground. The elevation alone.
final class DebugOverlaySunElevationView: NSView {
    var elevationDegrees: Double = 45 { didSet { needsDisplay = true } }
    var elevationRange: ClosedRange<Double> = 0 ... 90
    /// The sun dragged to an elevation, in degrees.
    var onChange: ((Double) -> Void)?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    /// The ground's point the light falls on, and the quarter circle's
    /// radius.
    private var geometry: (origin: CGPoint, radius: CGFloat) {
        let margin = DebugOverlaySunDialView.margin
        let radius = max(0, min(bounds.width - margin * 2, bounds.height - margin * 2))
        return (CGPoint(x: bounds.midX - radius / 2, y: bounds.minY + margin), radius)
    }

    override func draw(_: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let (origin, radius) = geometry

        let ground = NSBezierPath()
        ground.move(to: CGPoint(x: origin.x - 6, y: origin.y))
        ground.line(to: CGPoint(x: origin.x + radius + 4, y: origin.y))
        ground.lineWidth = 2
        NSColor(calibratedRed: 0.45, green: 0.65, blue: 0.4, alpha: 1).setStroke()
        ground.stroke()

        let arc = NSBezierPath()
        arc.appendArc(withCenter: origin, radius: radius, startAngle: 0, endAngle: 90)
        arc.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.7).setStroke()
        arc.stroke()

        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        for degrees in [30.0, 60.0] {
            let angle = degrees * .pi / 180
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: origin.x + CGFloat(cos(angle)) * (radius - 4), y: origin.y + CGFloat(sin(angle)) * (radius - 4)))
            tick.line(to: CGPoint(x: origin.x + CGFloat(cos(angle)) * radius, y: origin.y + CGFloat(sin(angle)) * radius))
            NSColor.white.withAlphaComponent(0.5).setStroke()
            tick.stroke()
            let text = "\(Int(degrees))°" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.5)]
            text.draw(at: CGPoint(x: origin.x + CGFloat(cos(angle)) * (radius - 22), y: origin.y + CGFloat(sin(angle)) * (radius - 22) - 5),
                      withAttributes: attributes)
        }

        let angle = elevationDegrees * .pi / 180
        let sun = CGPoint(x: origin.x + CGFloat(cos(angle)) * radius, y: origin.y + CGFloat(sin(angle)) * radius)
        let ray = NSBezierPath()
        ray.move(to: sun)
        ray.line(to: origin)
        ray.lineWidth = 1.5
        NSColor.systemYellow.withAlphaComponent(0.6).setStroke()
        ray.stroke()
        DebugOverlaySunDialView.drawSun(at: sun)
    }

    override func mouseDown(with event: NSEvent) {
        drag(to: event)
    }

    override func mouseDragged(with event: NSEvent) {
        drag(to: event)
    }

    private func drag(to event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let origin = geometry.origin
        let elevation = DebugOverlaySunDial.elevation(sidePoint: SIMD2<Double>(Double(location.x - origin.x),
                                                                               Double(location.y - origin.y)),
                                                      elevationRange: elevationRange)
        elevationDegrees = elevation
        onChange?(elevation)
    }
}

/// A slider with two knobs, for a range: the filled track between them.
/// A drag takes the nearer knob, and the knobs never pass each other.
final class DebugOverlayRangeSliderView: NSView {
    var range: ClosedRange<Double> = 0 ... 1 { didSet { needsDisplay = true } }
    var value: ClosedRange<Double> = 0 ... 1 { didSet { needsDisplay = true } }
    /// The step the knobs snap to.
    var step: Double = 0.1
    /// The range dragged to.
    var onChange: ((ClosedRange<Double>) -> Void)?

    private enum Knob { case lower, upper }
    private var draggedKnob: Knob?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    private static let knobRadius: CGFloat = 8
    private var track: (minX: CGFloat, maxX: CGFloat, y: CGFloat) {
        (bounds.minX + Self.knobRadius + 1, bounds.maxX - Self.knobRadius - 1, bounds.midY)
    }

    private func x(of value: Double) -> CGFloat {
        let (minX, maxX, _) = track
        let span = max(range.upperBound - range.lowerBound, 1e-9)
        return minX + CGFloat((value - range.lowerBound) / span) * (maxX - minX)
    }

    private func value(atX x: CGFloat) -> Double {
        let (minX, maxX, _) = track
        let share = Double(max(0, min(1, (x - minX) / max(maxX - minX, 1))))
        let raw = range.lowerBound + share * (range.upperBound - range.lowerBound)
        return step > 0 ? (raw / step).rounded() * step : raw
    }

    override func draw(_: NSRect) {
        let (minX, maxX, y) = track
        let base = NSBezierPath(roundedRect: CGRect(x: minX, y: y - 2, width: maxX - minX, height: 4), xRadius: 2, yRadius: 2)
        NSColor.white.withAlphaComponent(0.2).setFill()
        base.fill()
        let lowerX = x(of: value.lowerBound)
        let upperX = x(of: value.upperBound)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: CGRect(x: lowerX, y: y - 2, width: max(upperX - lowerX, 0), height: 4), xRadius: 2, yRadius: 2).fill()
        for knobX in [lowerX, upperX] {
            let knob = NSBezierPath(ovalIn: CGRect(x: knobX - Self.knobRadius, y: y - Self.knobRadius,
                                                   width: Self.knobRadius * 2, height: Self.knobRadius * 2))
            NSColor(white: 0.92, alpha: 1).setFill()
            knob.fill()
            NSColor.black.withAlphaComponent(0.3).setStroke()
            knob.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let lowerDistance = abs(location.x - x(of: value.lowerBound))
        let upperDistance = abs(location.x - x(of: value.upperBound))
        // Knobs on top of each other: the drag's way picks, the upper
        // to the right of them.
        if lowerDistance == upperDistance {
            draggedKnob = location.x >= x(of: value.upperBound) ? .upper : .lower
        } else {
            draggedKnob = lowerDistance < upperDistance ? .lower : .upper
        }
        drag(to: location)
    }

    override func mouseDragged(with event: NSEvent) {
        drag(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with _: NSEvent) {
        draggedKnob = nil
    }

    private func drag(to location: CGPoint) {
        guard let draggedKnob else { return }
        let dragged = value(atX: location.x)
        switch draggedKnob {
        case .lower:
            value = min(dragged, value.upperBound) ... value.upperBound
        case .upper:
            value = value.lowerBound ... max(dragged, value.lowerBound)
        }
        onChange?(value)
    }
}

#endif
