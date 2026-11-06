// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// How opaque the map's names and its POIs are, by the zoom: a factor over
/// each label's own opacity (`LabelTextStyle.opacity`), 0 to 1, so a name
/// laid over the land can fade as the map grows busy, or the POIs give way
/// to the places at the zooms where both stand.
///
/// Read at the zoom the labels are planned by
/// (`FrameContext.planningZoom`) on every frame, so a zoom gesture plays
/// the change. Drawn at frame time, never baked into the prepared tiles:
/// a change needs no re-parse, and the debug panel's Labels tab drags both
/// curves live over the style's.
///
///     ProtomapsBasemapMapStyle.default.apply { theme in
///         theme.labelOpacity.pois = [14: 0.6, 16: 1]
///     }
public struct ImmersiveMapLabelOpacity: Hashable, Sendable {
    /// Every name but the POIs': the places, the countries and the
    /// regions, the waters and the streets. 1 at every zoom by default.
    public var names: ImmersiveMapZoomCurve
    /// The POIs, their icon plates and their names alike. 1 at every zoom
    /// by default.
    public var pois: ImmersiveMapZoomCurve

    public init(names: ImmersiveMapZoomCurve = 1,
                pois: ImmersiveMapZoomCurve = 1) {
        self.names = names
        self.pois = pois
    }

    /// The two factors at a zoom, each held to 0...1.
    func frame(atZoom zoom: Double) -> LabelOpacityFrame {
        LabelOpacityFrame(names: min(max(names.value(atZoom: zoom), 0), 1),
                          pois: min(max(pois.value(atZoom: zoom), 0), 1))
    }
}

/// The label opacity of one frame (`ImmersiveMapLabelOpacity` read at the
/// frame's zoom): what every label drawer multiplies a label's own opacity
/// by, the POIs' factor for a POI's plate and name, the names' for the rest.
struct LabelOpacityFrame: Equatable, Sendable {
    var names: Float
    var pois: Float

    /// Every label at its own opacity.
    static let solid = LabelOpacityFrame(names: 1, pois: 1)

    /// The opacity a label of the style draws at.
    func opacity(of style: LabelTextStyle) -> Float {
        style.opacity * (style.isPointOfInterest ? pois : names)
    }
}
