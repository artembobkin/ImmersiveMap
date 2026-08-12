// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

@testable import ImmersiveMap
import AppKit
import XCTest

/// A trackpad zoom keeps moving the camera after the fingers lift, through
/// the system's momentum events. These pin that the interaction spans both
/// halves, because ending it at the lift drops the render loop back to on
/// demand for the rest of the movement, which is the judder a fast flick
/// shows and a slow zoom does not.
final class ScrollZoomInteractionPhaseResolverTests: XCTestCase {
    private func transition(phase: NSEvent.Phase,
                            momentum: NSEvent.Phase = []) -> ScrollZoomInteractionPhaseResolver.Transition? {
        ScrollZoomInteractionPhaseResolver.transition(phase: phase, momentumPhase: momentum)
    }

    func testFingersDownBeginsAndKeepsTheInteraction() {
        XCTAssertEqual(transition(phase: .began), .begin)
        XCTAssertNil(transition(phase: .changed),
                     "The middle of the gesture changes nothing")
    }

    func testMomentumCarriesTheInteractionPastTheLift() {
        XCTAssertEqual(transition(phase: [], momentum: .began), .begin,
                       "Deceleration is the same gesture continuing, so rendering stays continuous")
        XCTAssertNil(transition(phase: [], momentum: .changed),
                     "The middle of the deceleration changes nothing")
        XCTAssertEqual(transition(phase: [], momentum: .ended), .end,
                       "The interaction ends when the movement does")
        XCTAssertEqual(transition(phase: [], momentum: .cancelled), .end)
    }

    func testLiftWithoutMomentumEndsTheInteraction() {
        XCTAssertEqual(transition(phase: .ended), .end,
                       "A gesture the system sends no momentum for ends at the lift")
        XCTAssertEqual(transition(phase: .cancelled), .end)
    }

    /// The regression itself: a lift followed by momentum must not leave the
    /// loop on demand for the deceleration. Whatever the lift decides, the
    /// momentum that follows re-establishes the interaction.
    func testLiftFollowedByMomentumRestoresTheInteraction() {
        XCTAssertEqual(transition(phase: .ended), .end)
        XCTAssertEqual(transition(phase: [], momentum: .began), .begin)
        XCTAssertNil(transition(phase: [], momentum: .changed))
        XCTAssertEqual(transition(phase: [], momentum: .ended), .end)
    }

    /// AppKit reports the closing momentum event with an empty `phase`, and a
    /// closing finger-down event with an empty `momentumPhase`; a momentum
    /// end must win if both ever arrive together, since it is the later half.
    func testMomentumEndWinsOverAConcurrentPhaseBegan() {
        XCTAssertEqual(transition(phase: .began, momentum: .ended), .end)
    }
}

#endif
