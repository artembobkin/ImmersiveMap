// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics

/// Tap event on a shape of a layer of the app's data.
/// Delivered on every tap that lands on a shape the map shows, regardless
/// of selection state, including a repeated tap on an already selected one.
public struct ImmersiveMapLayerTapEvent {
    /// The layer the shape is drawn by, as it was at the moment of the tap.
    /// Its `source` names the registered data the shape comes from.
    public let layer: ImmersiveMapLayer
    /// The shape's id within the layer's source: the one it was given, a
    /// GeoJSON feature's numeric `id`, or its place in the source.
    public let shapeID: UInt64
    /// The place on the map under the tap.
    public let coordinate: GeoCoordinate
    /// Tap point in map view coordinates.
    public let screenPoint: CGPoint

    public init(layer: ImmersiveMapLayer,
                shapeID: UInt64,
                coordinate: GeoCoordinate,
                screenPoint: CGPoint) {
        self.layer = layer
        self.shapeID = shapeID
        self.coordinate = coordinate
        self.screenPoint = screenPoint
    }
}
