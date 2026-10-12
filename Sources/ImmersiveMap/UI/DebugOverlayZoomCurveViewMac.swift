// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit

/// A value over the camera zoom drawn as a graph in the debug panel, and
/// edited on it: the zoom runs across, the value up, the curve between its
/// stops as `ImmersiveMapZoomCurve` evaluates it, and a line marks the
/// camera's zoom with the value there.
///
/// - A click on empty graph adds a stop there (or moves the stop already at
///   that zoom), and the stop follows the pointer while the button is down.
/// - A drag of a stop moves it, across on the half zoom grid and up by
///   hundredths (`DebugOverlayZoomCurveAxes`).
/// - A double click or a right click on a stop removes it. The last stop
///   stays: a curve keeps at least one.
///
/// Every change is handed out at once through `onChange`, so the map follows
/// the drag. The arithmetic is `DebugOverlayZoomCurveEditing`'s.
final class DebugOverlayZoomCurveView: NSView {
    private enum Layout {
        /// Room under the plot for the zoom labels and left of it for the
        /// value labels.
        static let bottomInset: CGFloat = 14
        static let leftInset: CGFloat = 30
        static let topInset: CGFloat = 6
        static let rightInset: CGFloat = 8
        static let stopRadius: CGFloat = 4
        static let hitRadius: CGFloat = 8
        /// A zoom label every this many zoom levels.
        static let zoomLabelStep: Double = 2
    }

    var curve = ImmersiveMapZoomCurve(0) {
        didSet { if curve != oldValue { needsDisplay = true } }
    }
    var axes = DebugOverlayZoomCurveAxes(zoomRange: 0...22, valueRange: 0...1) {
        didSet { if axes != oldValue { needsDisplay = true } }
    }
    var cameraZoom: Double = 0 {
        didSet { if cameraZoom != oldValue { needsDisplay = true } }
    }
    /// How a value is printed on the graph: its axis ends and the label of
    /// the stop under the pointer.
    var valueText: (Double) -> String = { String(format: "%g", $0) }
    var isEnabled = true {
        didSet { if isEnabled != oldValue { needsDisplay = true } }
    }
    var onChange: ((ImmersiveMapZoomCurve) -> Void)?

    /// The stop a drag holds, by index in `curve`.
    private var draggedStop: Int?
    /// The stop under the pointer, labelled with its zoom and value.
    private var hoveredStop: Int? {
        didSet { if hoveredStop != oldValue { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    private var plotRect: CGRect {
        CGRect(x: bounds.minX + Layout.leftInset,
               y: bounds.minY + Layout.topInset,
               width: max(0, bounds.width - Layout.leftInset - Layout.rightInset),
               height: max(0, bounds.height - Layout.topInset - Layout.bottomInset))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let plot = plotRect
        let alpha: CGFloat = isEnabled ? 1 : 0.4

        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        drawGrid(in: plot, alpha: alpha)
        drawCurve(in: plot, alpha: alpha)
        drawCameraZoom(in: plot, alpha: alpha)
        drawStops(in: plot, alpha: alpha)
    }

    private func drawGrid(in plot: CGRect, alpha: CGFloat) {
        let gridColor = NSColor.white.withAlphaComponent(0.1 * alpha)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5 * alpha)
        ]
        var zoom = (axes.zoomRange.lowerBound / Layout.zoomLabelStep).rounded(.up) * Layout.zoomLabelStep
        while zoom <= axes.zoomRange.upperBound {
            let x = axes.x(zoom: zoom, in: plot)
            gridColor.setStroke()
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.line(to: CGPoint(x: x, y: plot.maxY))
            line.lineWidth = 1
            line.stroke()
            let text = NSAttributedString(string: String(format: "%.0f", zoom), attributes: labelAttributes)
            text.draw(at: CGPoint(x: x - text.size().width / 2, y: plot.maxY + 1))
            zoom += Layout.zoomLabelStep
        }
        for value in [axes.valueRange.lowerBound, axes.valueRange.upperBound] {
            let text = NSAttributedString(string: valueText(value), attributes: labelAttributes)
            let y = axes.y(value: value, in: plot)
            text.draw(at: CGPoint(x: plot.minX - text.size().width - 4, y: y - text.size().height / 2))
        }
        NSColor.white.withAlphaComponent(0.2 * alpha).setStroke()
        NSBezierPath(rect: plot).stroke()
    }

    private func drawCurve(in plot: CGRect, alpha: CGFloat) {
        guard plot.width > 1 else { return }
        let path = NSBezierPath()
        var x = plot.minX
        while x <= plot.maxX {
            let share = Double((x - plot.minX) / plot.width)
            let zoom = axes.zoomRange.lowerBound + share * (axes.zoomRange.upperBound - axes.zoomRange.lowerBound)
            let value = curve.value(atZoom: zoom, interpolation: axes.interpolation)
            let point = CGPoint(x: x, y: axes.y(value: Double(value), in: plot))
            if x == plot.minX { path.move(to: point) } else { path.line(to: point) }
            x += 1
        }
        path.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.85 * alpha).setStroke()
        path.stroke()
    }

    private func drawCameraZoom(in plot: CGRect, alpha: CGFloat) {
        let x = axes.x(zoom: cameraZoom, in: plot)
        let accent = NSColor.systemOrange.withAlphaComponent(alpha)
        accent.setStroke()
        let line = NSBezierPath()
        line.move(to: CGPoint(x: x, y: plot.minY))
        line.line(to: CGPoint(x: x, y: plot.maxY))
        line.lineWidth = 1
        line.setLineDash([3, 2], count: 2, phase: 0)
        line.stroke()
        let value = Double(curve.value(atZoom: cameraZoom, interpolation: axes.interpolation))
        let y = axes.y(value: value, in: plot)
        accent.setFill()
        NSBezierPath(ovalIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)).fill()
    }

    private func drawStops(in plot: CGRect, alpha: CGFloat) {
        for (index, stop) in curve.stops.enumerated() {
            let center = CGPoint(x: axes.x(zoom: stop.zoom, in: plot),
                                 y: axes.y(value: Double(stop.value), in: plot))
            let isActive = index == hoveredStop || index == draggedStop
            let radius = isActive ? Layout.stopRadius + 1.5 : Layout.stopRadius
            let dot = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                  width: radius * 2, height: radius * 2))
            (isActive ? NSColor.systemBlue : NSColor.white).withAlphaComponent(alpha).setFill()
            dot.fill()
            if isActive {
                drawStopLabel(stop, at: center, in: plot)
            }
        }
    }

    /// The zoom and the value of the stop under the pointer, beside it and
    /// kept inside the plot.
    private func drawStopLabel(_ stop: ImmersiveMapZoomCurve.Stop, at center: CGPoint, in plot: CGRect) {
        let zoom = stop.zoom == stop.zoom.rounded()
            ? String(format: "%.0f", stop.zoom)
            : String(format: "%.1f", stop.zoom)
        let text = NSAttributedString(
            string: "z\(zoom): \(valueText(Double(stop.value)))",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                         .foregroundColor: NSColor.white])
        let size = text.size()
        var origin = CGPoint(x: center.x + 8, y: center.y - size.height - 4)
        origin.x = min(origin.x, plot.maxX - size.width)
        origin.y = max(origin.y, plot.minY)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: CGRect(origin: origin, size: size).insetBy(dx: -3, dy: -1),
                     xRadius: 3, yRadius: 3).fill()
        text.draw(at: origin)
    }

    // MARK: - Editing

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        hoveredStop = stop(at: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredStop = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let index = stop(at: event) {
            if event.clickCount >= 2 {
                remove(index)
                return
            }
            draggedStop = index
            return
        }
        let plot = plotRect
        let edit = DebugOverlayZoomCurveEditing.settingStop(curve,
                                                             zoom: axes.zoom(x: point.x, in: plot),
                                                             value: axes.value(y: point.y, in: plot))
        draggedStop = edit.index
        publish(edit.curve)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let index = draggedStop else { return }
        let point = convert(event.locationInWindow, from: nil)
        let plot = plotRect
        let edit = DebugOverlayZoomCurveEditing.movingStop(curve,
                                                            at: index,
                                                            toZoom: axes.zoom(x: point.x, in: plot),
                                                            value: axes.value(y: point.y, in: plot))
        draggedStop = edit.index
        hoveredStop = edit.index
        publish(edit.curve)
    }

    override func mouseUp(with event: NSEvent) {
        draggedStop = nil
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled, let index = stop(at: event) else { return }
        remove(index)
    }

    private func remove(_ index: Int) {
        guard let edited = DebugOverlayZoomCurveEditing.removingStop(curve, at: index) else { return }
        hoveredStop = nil
        draggedStop = nil
        publish(edited)
    }

    private func stop(at event: NSEvent) -> Int? {
        DebugOverlayZoomCurveEditing.stopIndex(at: convert(event.locationInWindow, from: nil),
                                               curve: curve,
                                               axes: axes,
                                               rect: plotRect,
                                               radius: Layout.hitRadius)
    }

    private func publish(_ edited: ImmersiveMapZoomCurve) {
        guard edited != curve else { return }
        curve = edited
        onChange?(edited)
    }
}

#endif
