// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// What the country around the point the camera looks at is like, read
/// off the relief's own heights: mountains or a plain. Reported through
/// `ImmersiveMapView.onTerrainSurroundingsChange` whenever it changes, nil
/// while the map is off the terrain (the relief disabled, collapsed by the
/// zoom, or the globe on screen), for the effects an app turns on in the
/// mountains: a mountain atmosphere, a thinner air, a different light.
///
/// The reading is the span of the terrain's heights, its highest less its
/// lowest, over a disc of `TerrainSurroundingsSettings.sampleRadiusMetres`
/// around the point the camera looks at, smoothed over time
/// (`smoothingHalfLife`) so a pan does not flicker it. `mountainousness`
/// places the span between the settings' two thresholds, and `kind` is a
/// switch over the same thresholds with the band between them as its
/// hysteresis: it rises to `.mountains` once the span passes
/// `mountainsAboveMetres` and falls back to `.plain` once the span is
/// under `plainBelowMetres`, and holds in between.
public struct ImmersiveMapTerrainSurroundings: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case plain
        case mountains
    }

    /// Mountains or a plain, with the hysteresis described above.
    public let kind: Kind
    /// How mountainous the country is, 0 on a plain and 1 in the
    /// mountains, linear between the settings' two thresholds: for an
    /// effect blended rather than switched.
    public let mountainousness: Float
    /// The span of the terrain's heights over the sampled disc, in metres,
    /// as smoothed: what the two values above are read from.
    public let heightSpanMetres: Float
    /// The terrain under the point the camera looks at, in metres over the
    /// sea, the height the relief is drawn from (`GroundReliefStore.datumMetres`).
    public let groundMetres: Float

    public init(kind: Kind, mountainousness: Float, heightSpanMetres: Float, groundMetres: Float) {
        self.kind = kind
        self.mountainousness = mountainousness
        self.heightSpanMetres = heightSpanMetres
        self.groundMetres = groundMetres
    }
}
