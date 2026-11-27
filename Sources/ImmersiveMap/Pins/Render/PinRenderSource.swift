// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

/// The `Pins` folder: the engine-side model and CPU presentation of pin
/// pins, from the public pin data to the selection, clustering and
/// presentation state the renderer reads through this protocol. It holds no
/// Metal, no tile or label logic, no views or gestures, and no credentials
/// (`PinImageLoader` fetches pin images from plain URLs). Drawing
/// is `Pins`.
protocol PinRenderSource: AnyObject {
    var currentPinController: ImmersiveMapPinsController? { get }
}
