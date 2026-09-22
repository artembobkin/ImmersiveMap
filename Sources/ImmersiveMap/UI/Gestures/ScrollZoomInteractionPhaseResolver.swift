// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit

/// Decides when a trackpad zoom counts as an interaction in progress.
///
/// A scroll gesture on a trackpad has two halves. While the fingers are down
/// the events carry `phase`; after they lift, the system keeps sending
/// decelerating events that carry `momentumPhase` instead, and those move the
/// camera exactly like the first half did. Ending the interaction when the
/// fingers lift therefore ends it in the middle of the movement: the render
/// loop drops back to on demand and the rest of the zoom is drawn one
/// requested frame at a time on a display link that is paused and unpaused
/// again for each one. Measured on a 50 Hz display, that doubles the p90 gap
/// between frames (1.43 to 2.00 refreshes) and raises the share of gaps above
/// 1.5 refreshes from 8% to 20%, which is the visible judder, and it appears
/// only on a fast flick because a slow zoom carries almost no momentum.
enum ScrollZoomInteractionPhaseResolver {
    enum Transition: Equatable {
        case begin
        case end
    }

    /// nil means "no change": the middle of either half of the gesture.
    static func transition(phase: NSEvent.Phase,
                           momentumPhase: NSEvent.Phase) -> Transition? {
        if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) {
            return .end
        }
        if momentumPhase.contains(.began) {
            // The deceleration is the same gesture continuing, so rendering
            // stays continuous through it.
            return .begin
        }
        if phase.contains(.began) {
            return .begin
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            // Fingers up. Momentum, if the system decides to send any, opens
            // with its own `began` and takes over from here.
            return .end
        }
        return nil
    }
}

#endif
