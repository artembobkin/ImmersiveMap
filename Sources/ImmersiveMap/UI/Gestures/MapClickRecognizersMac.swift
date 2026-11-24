// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

#if os(macOS)
import AppKit

/// How far the cursor has moved between two events, in points.
private func travel(from start: CGPoint, to event: NSEvent) -> CGFloat {
    hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
}

/// A pan that does not begin until the cursor has left the spot the button
/// went down on by more than a tolerance. A hand that clicks moves the
/// mouse a point or two between the press and the release, and a plain pan
/// recognizer takes that for a drag: the map shifts and the click is lost.
/// Within the tolerance the drag is kept from the recognizer, so it stays
/// a click (`MapClickObserver`), and past it the pan goes on as ever.
final class MapPanGestureRecognizer: NSPanGestureRecognizer {
    /// The tolerance, in points, read at every drag so a setting applies
    /// live (`CameraSettings.tapMovementTolerancePoints`).
    var tolerance: () -> CGFloat = { 4 }

    private var downLocation: CGPoint?
    private var hasLeft = false

    private func begin(_ event: NSEvent) {
        downLocation = event.locationInWindow
        hasLeft = false
    }

    /// Whether the drag is the recognizer's yet.
    private func leaves(_ event: NSEvent) -> Bool {
        if hasLeft { return true }
        guard let downLocation else { return true }
        hasLeft = travel(from: downLocation, to: event) > tolerance()
        return hasLeft
    }

    override func mouseDown(with event: NSEvent) {
        begin(event)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if leaves(event) { super.mouseDragged(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        begin(event)
        super.rightMouseDown(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        if leaves(event) { super.rightMouseDragged(with: event) }
    }

    override func reset() {
        downLocation = nil
        hasLeft = false
        super.reset()
    }
}

/// Sees the presses on the map: a button going down and coming up without
/// the cursor leaving the spot by more than the pan's tolerance. It only
/// watches. It never recognizes, so it takes no event from the pan, the
/// tilt or the pinch, and whether a press is a click or half of a double
/// click is worked out from the presses it reports (`MapClickSequence`),
/// not by recognizers that wait on each other.
final class MapClickObserver: NSGestureRecognizer {
    enum Button {
        case primary
        case secondary
    }

    /// The same tolerance as the pan's: a movement is one or the other.
    var tolerance: () -> CGFloat = { 4 }
    /// A press: the button, where it came up in the window, and when.
    var onPress: ((Button, CGPoint, TimeInterval) -> Void)?

    private var downLocation: CGPoint?

    private func release(_ button: Button, _ event: NSEvent) {
        defer {
            downLocation = nil
            state = .failed
        }
        guard let downLocation, travel(from: downLocation, to: event) <= tolerance() else { return }
        onPress?(button, event.locationInWindow, event.timestamp)
    }

    /// The cursor left the spot: this is a drag, and no press.
    private func drag(_ event: NSEvent) {
        guard let downLocation, travel(from: downLocation, to: event) > tolerance() else { return }
        self.downLocation = nil
        state = .failed
    }

    override func mouseDown(with event: NSEvent) { downLocation = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) { drag(event) }
    override func mouseUp(with event: NSEvent) { release(.primary, event) }
    override func rightMouseDown(with event: NSEvent) { downLocation = event.locationInWindow }
    override func rightMouseDragged(with event: NSEvent) { drag(event) }
    override func rightMouseUp(with event: NSEvent) { release(.secondary, event) }

    override func reset() {
        downLocation = nil
        super.reset()
    }
}
#endif
