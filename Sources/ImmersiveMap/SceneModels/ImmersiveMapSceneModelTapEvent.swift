// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics

/// Tap event on a 3D scene model.
/// Delivered on every tap that lands on the model's geometry, regardless of
/// selection state, including a repeated tap on an already selected model.
public struct ImmersiveMapSceneModelTapEvent {
    /// Snapshot of the model descriptor at the moment of the tap.
    public let model: ImmersiveMapSceneModel
    /// Where the model was drawn when it was tapped. During a path animation
    /// this is the point of the flight the model had reached, while
    /// `model.coordinate` already holds the path's destination.
    public let coordinate: GeoCoordinate
    /// Tap point in map view coordinates.
    public let screenPoint: CGPoint

    public init(model: ImmersiveMapSceneModel,
                coordinate: GeoCoordinate,
                screenPoint: CGPoint) {
        self.model = model
        self.coordinate = coordinate
        self.screenPoint = screenPoint
    }
}
