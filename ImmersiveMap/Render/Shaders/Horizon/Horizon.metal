// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

// The horizon layer: the air around the surface's visible edge, resolved per
// pixel from the view ray. The edge is the limb of the sphere the surface
// currently lives on (the resting globe, or the growing sphere of the
// unroll) and, at zero curvature, the plane's horizon; the CPU hands the
// edge over as the eye's local vertical plus the limb's depression below
// it, so the fragment never touches the sphere's centre coordinate and the
// plane is not a special case (HorizonEdgeMath.swift mirrors the angle).
//
// One shading function, two draws of the world pass right after the last
// world layer, split by the depth buffer: the sky side runs under the
// far-plane lessEqual test and reaches only pixels nothing painted (space,
// coverage holes, the polar caps, which write no depth), the ground side
// under a far-plane greater test and reaches only painted pixels, with its
// angle clamped to the edge so the whitening lands on the rasterized limb.
// Each pixel is shaded once. Pure arithmetic, no texture reads, no discard.
//
// One geometry feeds it on both surfaces: the band, a static mesh of
// directions around the eye's local vertical at a few angles either side of
// the edge (HorizonBandMesh.swift). Its vertices sit a unit from the eye, so
// the direction interpolated across a triangle is exactly the ray through
// the pixel and no fragment recovers a ray from the projection. On the
// globe the band ends where the halo has decayed; on the plane its top
// follows the highest corner of the frame, since the sky is opaque all the
// way up.
//
// Three things share the profile (HorizonFrameResolver.swift decides their
// strengths per frame): the globe's atmosphere (the band and glow outside
// the limb, the rim inside, the whitening at it), the limb feather (a glow
// a couple of pixels wide across the edge that hides the tile mesh's chord
// polygon and the silhouette's staircase) and the flat map's fog: the sky
// painted opaque above the line (a glow of the tint at the line decaying
// into the sky colour, under whatever is left of the halo through the
// morph) and the haze below it, the ground profile with its angles set
// from the haze's camera-distance range on the CPU.
//
// Layout mirrors HorizonUniform.swift (pinned by HorizonUniformLayoutTests).
struct Horizon {
    float3 up;
    float depression;
    float3 center;
    float sunInfluence;
    float3 light;
    float skyStrength;
    float3 tint;
    float whitenWeight;
    float3 eye;
    float featherStrength;
    float bandRadians;
    float glowRadians;
    float whitenRadians;
    float featherRadians;
    float groundBandRadians;
    float groundGain;
    float cutoffStartRadians;
    float cutoffEndRadians;
    float3 skyColor;
    float skyOpacity;
    float skyGradientRadians;
    float4x4 viewProjection;
    float bandTopRadians;
};

/// True for the ground-side draw: the angle is clamped to the edge, so a
/// painted pixel the analytic edge would put in the sky (the limb pixel
/// itself, under float noise) takes the edge's own value.
constant bool kHorizonGroundSide [[function_constant(0)]];

// The sky side's profile, weights of the band hugging the edge and of the
// wide glow away from it. Mirrored by HorizonFrameResolverTests through the
// shader source.
constant float kHorizonBandWeight = 0.85;
constant float kHorizonGlowWeight = 0.22;

/// Signed angle of a unit view direction above the edge: its elevation over
/// the eye's local horizontal plus the limb's depression. Mirrored by
/// HorizonEdgeMath.angleAboveEdge.
static inline float horizonAngleAboveEdge(constant Horizon& horizon, float3 direction) {
    return asin(clamp(dot(direction, horizon.up), -1.0, 1.0)) + horizon.depression;
}

/// The atmosphere outside the edge: a bright band hugging the limb (the
/// dense air) and a wide faint glow into space (the thin air).
static inline float horizonSkyProfile(constant Horizon& horizon, float aboveRadians) {
    float band = exp(-aboveRadians / horizon.bandRadians);
    float glow = exp(-aboveRadians / horizon.glowRadians);
    return saturate(band * kHorizonBandWeight + glow * kHorizonGlowWeight);
}

/// The haze over the surface below the edge: one exponential with a gain
/// (above one it saturates at the line, which is the fog band), cut off
/// smoothly so the map under the camera stays byte-clean. Mirrored by
/// HorizonFrameResolver.groundProfile.
static inline float horizonGroundProfile(constant Horizon& horizon, float belowRadians) {
    float amount = saturate(exp(-belowRadians / horizon.groundBandRadians) * horizon.groundGain);
    float cutoff = 1.0 - smoothstep(horizon.cutoffStartRadians, horizon.cutoffEndRadians, belowRadians);
    return amount * cutoff;
}

/// The sun's side of the limb: the halo is full where the limb normal faces
/// the scene light and dims to a residual glow opposite it, by the frame's
/// sun influence (zero on the plane and with the atmosphere off).
static inline float horizonSunFactor(constant Horizon& horizon, float3 direction) {
    if (horizon.sunInfluence <= 0.0) {
        return 1.0;
    }
    float3 toCenter = horizon.center - horizon.eye;
    float3 nearest = horizon.eye + direction * max(dot(toCenter, direction), 0.0);
    float3 normal = normalize(nearest - horizon.center);
    float day = smoothstep(-0.25, 0.25, dot(normal, horizon.light));
    return 1.0 - horizon.sunInfluence * (1.0 - day);
}

/// The haze of one direction, `above` radians above the edge (already
/// clamped to the edge on the ground side), premultiplied over what is
/// behind: the tint, whitened toward the edge, weighted by the coverage;
/// the coverage in alpha, so the air covers the edge and thins to nothing
/// both into space and over the map.
static inline half4 horizonShade(constant Horizon& horizon, float above, float3 direction) {
    float haze;
    if (above >= 0.0) {
        haze = horizonSkyProfile(horizon, above) * horizon.skyStrength * horizonSunFactor(horizon, direction);
    } else {
        haze = horizonGroundProfile(horizon, -above);
    }
    float distanceToEdge = abs(above);
    float feather = exp(-distanceToEdge / horizon.featherRadians) * horizon.featherStrength;
    float whiten = exp(-distanceToEdge / horizon.whitenRadians) * horizon.whitenWeight;

    float coverage = saturate(haze + feather * (1.0 - haze));
    float3 color = mix(horizon.tint, float3(1.0), whiten) * coverage;
    if (!kHorizonGroundSide && above >= 0.0 && horizon.skyOpacity > 0.0) {
        // The plane's sky under the halo: a glow of the tint at the line,
        // so the sky meets the haze in one colour, decaying into the sky
        // colour over a few e-folds; faded in through the morph by the
        // opacity.
        float gradient = 1.0 - exp(-above / horizon.skyGradientRadians);
        float3 sky = mix(horizon.tint, horizon.skyColor, gradient) * horizon.skyOpacity;
        color += sky * (1.0 - coverage);
        coverage += horizon.skyOpacity * (1.0 - coverage);
    }
    return half4(half3(color), half(coverage));
}

// The band. A vertex is a station (one of the angles either side of the
// edge the band is strung between, HorizonBandMath.swift mirrors them) and
// an azimuth about the eye's local vertical; the shader turns the pair into
// a direction, places it a unit away from the eye and lifts the clip depth
// to the far plane, where the two depth tests of the layer compare against
// the cleared depth (sky side) and against everything nearer (ground). What travels to the fragment is the
// direction, not the angle: interpolated across the flat triangle it is
// exactly the ray through the pixel, whatever the triangle's size, whereas
// an interpolated angle is only right at the vertices and facets a band
// whose quads span tens of degrees low over the planet.
struct HorizonBandVertexIn {
    float azimuth [[attribute(0)]];
    float station [[attribute(1)]];
};

struct HorizonBandVertexOut {
    float4 position [[position]];
    float3 direction;
};

constant int kHorizonBandStations = 8;

/// The band's angles above the edge, station by station, from the rim's
/// far cutoff under the edge to the band's top (the CPU's choice: the
/// decayed halo on the globe, the frame's highest corner on the plane);
/// the edge itself is a station, and one either side of it is at least
/// four feather widths out so the feather's ramp gets its own quads. Kept in order by
/// a running maximum, so a wide feather on a small drawable can never fold
/// a quad over the previous one, and kept on the sphere of directions:
/// low over the planet the glow reaches its 45 degree cap, and five of
/// those would carry the outer station past the zenith and fold the band
/// back over itself.
static inline float horizonBandStationAngle(constant Horizon& horizon, int station) {
    float feather = horizon.featherRadians * 4.0;
    float angles[kHorizonBandStations] = {
        -horizon.cutoffEndRadians,
        -horizon.cutoffStartRadians,
        -max(horizon.groundBandRadians, feather),
        0.0,
        max(horizon.bandRadians, feather),
        horizon.bandRadians * 3.0,
        horizon.glowRadians,
        horizon.bandTopRadians
    };
    float angle = angles[0];
    for (int index = 1; index <= station; index += 1) {
        angle = max(angle, angles[index]);
    }
    const float limit = 0.5 * M_PI_F - 1e-3;
    return clamp(angle, horizon.depression - limit, horizon.depression + limit);
}

vertex HorizonBandVertexOut horizonBandVertexShader(HorizonBandVertexIn in [[stage_in]],
                                                    constant Horizon& horizon [[buffer(1)]]) {
    float above = horizonBandStationAngle(horizon, int(in.station));
    // A basis across the local vertical; which one does not matter, the
    // band wraps all the way round.
    float3 reference = abs(horizon.up.z) < 0.9 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 east = normalize(cross(reference, horizon.up));
    float3 north = cross(horizon.up, east);
    float elevation = above - horizon.depression;
    float3 direction = cos(elevation) * (cos(in.azimuth) * east + sin(in.azimuth) * north)
        + sin(elevation) * horizon.up;
    HorizonBandVertexOut out;
    out.position = horizon.viewProjection * float4(horizon.eye + direction, 1.0);
    // At the far plane.
    out.position.z = out.position.w;
    out.direction = direction;
    return out;
}

fragment half4 horizonBandFragmentShader(HorizonBandVertexOut in [[stage_in]],
                                         constant Horizon& horizon [[buffer(0)]]) {
    float3 direction = normalize(in.direction);
    float above = horizonAngleAboveEdge(horizon, direction);
    if (kHorizonGroundSide) {
        above = min(above, 0.0);
    }
    return horizonShade(horizon, above, direction);
}
