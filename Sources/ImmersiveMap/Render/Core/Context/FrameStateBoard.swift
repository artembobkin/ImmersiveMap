// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

/// What a feature tells the rest of the frame: a value a subsystem writes
/// in `update` or `prepareGPU` and the subsystems after it read
/// (`FrameStateBoard`). A feature declares its state in its own folder.
/// `init()` is the state of a frame nothing has written yet.
protocol FrameState {
    init()
}

/// The frame's board: the states the subsystems leave for each other, one
/// per type, made anew for every frame. `Render` names none of them: a
/// feature declares its state as a `FrameState` in its own folder, writes it
/// with `frameContext.state[Its.self]` and whoever needs it reads it the
/// same way, so what passes between two features is stated where the two
/// meet and nowhere else. A state nothing has written reads as its `init()`.
///
/// The order of the subsystems (`RenderGraphFactory`) is what decides who
/// sees whose state: a subsystem reads what the ones before it wrote.
/// Main-thread, as the frame is.
final class FrameStateBoard {
    private var states: [ObjectIdentifier: any FrameState] = [:]

    subscript<State: FrameState>(_ type: State.Type) -> State {
        get {
            states[ObjectIdentifier(type)] as? State ?? State()
        }
        set {
            states[ObjectIdentifier(type)] = newValue
        }
    }
}

/// Whether the buildings, the trees or the models are rising out of the
/// ground this frame, raised in `update` by whichever of them is: the
/// frames keep coming until all of them stand.
struct ExtrusionRiseFrameState: FrameState {
    var isRising = false
}

/// The world's depth, for a layer that reads it after the world pass.
struct SceneDepthFrameState: FrameState {
    /// Whether a label layer reads the world's depth this frame, asked in
    /// `update` (`RoadLabelDrawSubsystem`): the world pass then keeps its
    /// depth instead of dropping it when the pass ends.
    var isRequestedForLabels = false
    /// The world's depth as the label pass reads it, single-sampled: set by
    /// the pass plan when it was kept, nil otherwise. Only the buildings and
    /// the models write real depth in it. The ground writes a band at the
    /// far plane, farther than anything real.
    var texture: MTLTexture?
}
