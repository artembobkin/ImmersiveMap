// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  LabelOcclusionProbe.metal
//  ImmersiveMap
//

#include <metal_stdlib>
using namespace metal;
#include "../../../Render/Shaders/Shared/RenderUniforms.h"

// One probe per point label, in the world pass after the buildings and the
// models: a few pixels at the label's anchor, depth-tested against what
// the pass drew and never painted. The fragment runs only where the test
// passed (early fragment tests) and marks the label as in view. A label
// whose anchor lies behind a wall or a model gets no fragment and stays 0.
//
// The layout mirrors LabelOcclusionProbe.Input (Swift): 32 bytes, the
// position packed.
struct LabelOcclusionProbeInput {
    // Where the label draws: on the ground, or on its roof for the label
    // naming the building.
    packed_float3 worldPosition;
    // The roof of the building the label stands in, in world Z; the
    // ground's level where it stands in none.
    float roofZ;
    // 0 for a label with no drawable anchor this frame: the probe is
    // clipped away and the label is not in view.
    uint enabled;
    uint _padding0;
    uint _padding1;
    uint _padding2;
};

struct LabelOcclusionProbeVertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    uint labelIndex [[flat]];
};

// A label inside a building is probed where the eye ray of its anchor
// leaves the building: the point of the ray at the roof's height. On the
// eye ray the probe keeps the anchor's own pixel, so it is on screen
// whenever the anchor is, even when the roof itself is above the top of
// the frame; at the roof's height it is clear of the building's walls,
// which are what would otherwise hide a label drawn on the ground floor.
// A taller building or a model in front still covers it. A camera below
// the roof looks at the facade itself: the ray is followed almost to the
// eye and the label shows.
constant float kLabelOcclusionProbeMaximumRayShare = 0.95;

// How far the probe then moves toward the eye, as a fraction of the
// distance. A probe at the roof's height lies exactly on the roof the
// buildings drew, and one on the ground touches the ground: the step
// keeps it clear of the surface it stands on without leaving the pixel,
// since the eye ray does not move on screen. A wall between the probe and
// the camera is nearer by far more than the step.
constant float kLabelOcclusionProbeEyeStep = 0.01;

// The probe covers the pixels around the anchor rather than one, so a
// multisampled pass always lands samples on it, and an anchor on the rim
// of a roof reads the roof beside it rather than the wall under it.
constant float kLabelOcclusionProbePointSize = 3.0;

vertex LabelOcclusionProbeVertexOut labelOcclusionProbeVertex(const device LabelOcclusionProbeInput* inputs [[buffer(0)]],
                                                              constant Camera& camera [[buffer(1)]],
                                                              uint vertexId [[vertex_id]]) {
    LabelOcclusionProbeInput input = inputs[vertexId];
    LabelOcclusionProbeVertexOut out;
    out.labelIndex = vertexId;
    out.pointSize = kLabelOcclusionProbePointSize;
    if (input.enabled == 0) {
        // Behind the near plane: clipped, no fragment, the label stays 0.
        out.position = float4(0.0, 0.0, -1.0, 1.0);
        return out;
    }
    float3 anchor = float3(input.worldPosition);
    float3 toEye = camera.eye - anchor;
    // The share of the eye ray that climbs from the anchor to the roof's
    // height: none for a label already on its roof, all of it (capped)
    // for a camera under the roof.
    float climb = input.roofZ - anchor.z;
    float share = 0.0;
    if (climb > 0.0) {
        share = toEye.z > climb
            ? climb / toEye.z
            : kLabelOcclusionProbeMaximumRayShare;
        share = min(share, kLabelOcclusionProbeMaximumRayShare);
    }
    float3 exit = anchor + toEye * share;
    float3 probe = exit + (camera.eye - exit) * kLabelOcclusionProbeEyeStep;
    out.position = camera.matrix * float4(probe, 1.0);
    return out;
}

// No color is written (the pipeline masks every channel): the fragment
// exists for its side effect alone. Early fragment tests make the depth
// test run first, so a hidden probe never reaches this function.
[[early_fragment_tests]]
fragment void labelOcclusionProbeFragment(LabelOcclusionProbeVertexOut in [[stage_in]],
                                          device uint* inView [[buffer(0)]]) {
    inView[in.labelIndex] = 1u;
}

