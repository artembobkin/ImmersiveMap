// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The `Avatars` folder: the engine-side model and CPU presentation of avatar
/// markers, from the public marker data to the selection, clustering and
/// presentation state the renderer reads through this protocol. It holds no
/// Metal, no tile or label logic, no views or gestures, and no credentials
/// (`AvatarMarkerImageLoader` fetches marker images from plain URLs). Drawing
/// is `Render/Avatars`.
protocol AvatarRenderSource: AnyObject {
    var currentAvatarController: ImmersiveMapAvatarsController? { get }
}
