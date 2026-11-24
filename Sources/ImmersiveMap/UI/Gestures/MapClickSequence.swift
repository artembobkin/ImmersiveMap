// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// Tells a click from a double click on macOS, from the presses the map
/// sees (`MapClickObserver`): a press is a button going down and coming up
/// on one spot. Two presses near each other within the system's double
/// click interval are a double click. While a double click means something
/// on the map, a press is not known to be a click until that interval has
/// passed with no second press, and it waits. When it means nothing, every
/// press is a click at once. Pure: the gesture controller owns the timer.
struct MapClickSequence {
    enum Outcome: Equatable {
        /// The press is a click, now.
        case click
        /// The press may be the first of a double click: it is a click if
        /// `expire(pressedAt:)` still finds it after the interval.
        /// `flushed`: an earlier press that was waiting and is now known
        /// to be a click of its own, since this press came too late or too
        /// far to pair with it.
        case pending(flushed: CGPoint?)
        /// The press completes a double click.
        case doubleClick
    }

    private var waiting: (point: CGPoint, time: TimeInterval)?

    /// A press at `point` at `time`. `reach`: how far apart the two
    /// presses of a double click may be. `waitsForDouble`: whether a
    /// double click means anything on the map now.
    mutating func press(at point: CGPoint,
                        time: TimeInterval,
                        interval: TimeInterval,
                        reach: CGFloat,
                        waitsForDouble: Bool) -> Outcome {
        let earlier = waiting
        waiting = nil
        guard waitsForDouble else { return .click }
        if let earlier {
            if time - earlier.time <= interval, hypot(point.x - earlier.point.x, point.y - earlier.point.y) <= reach {
                return .doubleClick
            }
            waiting = (point, time)
            return .pending(flushed: earlier.point)
        }
        waiting = (point, time)
        return .pending(flushed: nil)
    }

    /// The interval after the press at `time` has passed: where it was, if
    /// it is still waiting and so was a click, nil if a second press took
    /// it into a double click or flushed it.
    mutating func expire(pressedAt time: TimeInterval) -> CGPoint? {
        guard let waiting, waiting.time == time else { return nil }
        self.waiting = nil
        return waiting.point
    }
}
