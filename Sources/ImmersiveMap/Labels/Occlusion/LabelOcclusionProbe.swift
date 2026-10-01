// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// Whether each point label's anchor is in view or behind a building or a
/// model, asked of the GPU and answered a few frames later.
///
/// The labels draw in the overlay pass over their own cleared depth, and
/// the world pass keeps its depth only while it runs (memoryless, never
/// stored), so the question is asked inside the world pass: after the
/// buildings and the models, one point per label is rasterized at the
/// anchor, depth-tested and never painted, and its fragment writes 1 into
/// the label's slot of a shared buffer (`LabelOcclusionProbe.metal`). The
/// CPU reads that buffer in the frame that reuses the slot, when the GPU
/// is done with it, a few frames of lag that the fades hide. A label on a roof stands exactly on the roof
/// its building drew and passes: the probe steps a little toward the eye
/// to keep clear of the surface it stands on.
///
/// The answers are index-aligned with the working set and carried across
/// a topology change with each surviving tile's run, like the fades. A
/// label new to the set counts as hidden until its first answer, so it
/// fades in once, in view, instead of appearing over a building and fading
/// out again. The answer
/// for a projection (a pose, a set, the drawn models) is asked for in every
/// frame until it comes back, so a camera that stops still gets the answer
/// for where it stopped.
final class LabelOcclusionProbe {
    /// Mirrors `LabelOcclusionProbeInput` in LabelOcclusionProbe.metal.
    struct Input {
        /// Where the label draws.
        var worldX: Float
        var worldY: Float
        var worldZ: Float
        /// The roof of the building the label stands in, in world Z.
        var roofZ: Float
        /// 0 when the label has no drawable anchor this frame.
        var enabled: UInt32
        var padding0: UInt32 = 0
        var padding1: UInt32 = 0
        var padding2: UInt32 = 0
    }

    private struct Stamp {
        let projectionGeneration: UInt64
        let topologyGeneration: UInt64
        let count: Int
    }

    private let pipeline: LabelOcclusionProbePipeline
    private let inputBufferStore: FrameSlottedDynamicMetalBuffer<Input>
    private let inViewBufferStore: FrameSlottedDynamicMetalBuffer<UInt32>
    /// What each slot's buffers hold once its frame is committed.
    private var stamps: [Stamp?]
    /// The probe encoded into the current frame, kept out of `stamps`
    /// until the command buffer is committed: a frame dropped after
    /// prepareGPU never runs it.
    private var pendingStamp: (slot: Int, stamp: Stamp)?
    /// Whether the probe ran in the last frame that began: what a label
    /// new to the set is assumed to be until answered.
    private var wasActive = false
    /// The projection the last answer read was asked for.
    private var answeredProjectionGeneration: UInt64?

    /// Index-aligned with the working set: true where the anchor is behind
    /// something the world pass drew, or not answered yet.
    private(set) var occluded: [Bool] = []

    init(metalDevice: MTLDevice, pipeline: LabelOcclusionProbePipeline) {
        self.pipeline = pipeline
        self.inputBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                               slotsCount: InFlightFramePool.inFlightFramesCount,
                                                               options: [.storageModeShared])
        self.inViewBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                options: [.storageModeShared])
        self.stamps = Array(repeating: nil, count: InFlightFramePool.inFlightFramesCount)
    }

    // MARK: - The working set

    /// Binds the answers to the set after a topology change. A run that
    /// survived keeps its answers at its new place. A new label is hidden
    /// until answered while the probe runs, and in view while it does
    /// not, so switching the probe on hides nothing that was shown.
    func rebind(change: LabelWorkingSetChange) {
        occluded = change.carry(occluded, initial: wasActive)
        // The answers in flight were asked for the old indices.
        for index in stamps.indices {
            stamps[index] = nil
        }
        pendingStamp = nil
    }

    // MARK: - The frame

    /// Reads the answer the frame's slot holds, when there is one for the
    /// current set, into `occluded`; with the probe off, every label is in
    /// view. Returns whether any answer changed, which a frame that would
    /// otherwise keep its last collision decision must re-solve for.
    @discardableResult
    func beginFrame(active: Bool, slot: Int, topologyGeneration: UInt64) -> Bool {
        wasActive = active
        guard active else {
            answeredProjectionGeneration = nil
            var changed = false
            for index in occluded.indices where occluded[index] {
                occluded[index] = false
                changed = true
            }
            return changed
        }
        guard stamps.indices.contains(slot), let stamp = stamps[slot] else {
            return false
        }
        stamps[slot] = nil
        guard stamp.topologyGeneration == topologyGeneration else {
            return false
        }
        answeredProjectionGeneration = stamp.projectionGeneration
        let count = min(stamp.count, occluded.count)
        guard count > 0 else {
            return false
        }
        let inputs = UnsafeBufferPointer(start: inputBufferStore.buffer(for: slot).contents()
                                             .assumingMemoryBound(to: Input.self),
                                         count: count)
        let inView = UnsafeBufferPointer(start: inViewBufferStore.buffer(for: slot).contents()
                                             .assumingMemoryBound(to: UInt32.self),
                                         count: count)
        var changed = false
        for index in 0..<count {
            // A label without a drawable anchor was not asked about, and
            // is not in the way of anything either.
            let hidden = inputs[index].enabled != 0 && inView[index] == 0
            if occluded[index] != hidden {
                occluded[index] = hidden
                changed = true
            }
        }
        return changed
    }

    /// Whether the answer for `projectionGeneration` is still to come:
    /// the frame that asks must be followed by frames until it does.
    func awaitsAnswer(projectionGeneration: UInt64) -> Bool {
        wasActive && answeredProjectionGeneration != projectionGeneration
    }

    /// Fills the slot's probes from the frame's projection and clears the
    /// slot's answers. `probes` and `screenPoints` are the projection's,
    /// index-aligned with the set: each probe is where the label draws
    /// (xyz) and the roof of the building it stands in (w).
    func prepareGPU(slot: Int,
                    probes: [SIMD4<Float>],
                    screenPoints: [ScreenPointOutput],
                    projectionGeneration: UInt64,
                    topologyGeneration: UInt64) {
        pendingStamp = nil
        let count = min(probes.count, min(screenPoints.count, occluded.count))
        guard wasActive, count > 0 else {
            return
        }
        let inputBuffer = inputBufferStore.ensureCapacity(slot: slot, count: count)
        let inputs = inputBuffer.contents().assumingMemoryBound(to: Input.self)
        for index in 0..<count {
            let probe = probes[index]
            inputs[index] = Input(worldX: probe.x,
                                  worldY: probe.y,
                                  worldZ: probe.z,
                                  roofZ: probe.w,
                                  enabled: screenPoints[index].visible != 0 ? 1 : 0)
        }
        let inViewBuffer = inViewBufferStore.ensureCapacity(slot: slot, count: count)
        inViewBuffer.contents().initializeMemory(as: UInt8.self,
                                                 repeating: 0,
                                                 count: count * MemoryLayout<UInt32>.stride)
        pendingStamp = (slot, Stamp(projectionGeneration: projectionGeneration,
                                    topologyGeneration: topologyGeneration,
                                    count: count))
    }

    /// Draws the frame's probes: in the world pass, after everything that
    /// can hide a label.
    func encode(encoder: MTLRenderCommandEncoder,
                cameraUniform: CameraUniform,
                slot: Int,
                depthDisabledState: MTLDepthStencilState) {
        guard let pending = pendingStamp, pending.slot == slot else {
            return
        }
        var camera = cameraUniform
        encoder.setRenderPipelineState(pipeline.pipelineState)
        encoder.setDepthStencilState(pipeline.depthState)
        encoder.setVertexBuffer(inputBufferStore.buffer(for: slot), offset: 0, index: 0)
        encoder.setVertexBytes(&camera, length: MemoryLayout<CameraUniform>.stride, index: 1)
        encoder.setFragmentBuffer(inViewBufferStore.buffer(for: slot), offset: 0, index: 0)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pending.stamp.count)
        encoder.setDepthStencilState(depthDisabledState)
    }

    /// The frame's command buffer is committed: the probe will run and
    /// the slot's answer can be read when the slot comes round.
    func frameCommitted() {
        guard let pending = pendingStamp, stamps.indices.contains(pending.slot) else {
            return
        }
        stamps[pending.slot] = pending.stamp
        pendingStamp = nil
    }

    func reset() {
        occluded.removeAll(keepingCapacity: false)
        for index in stamps.indices {
            stamps[index] = nil
        }
        pendingStamp = nil
        wasActive = false
        answeredProjectionGeneration = nil
    }
}
