// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMap

/// The `ImmersiveMapDebug` product: the debug panel drawn over the map,
/// kept apart from the engine so an app that links `ImmersiveMap` alone
/// carries nothing of it. The engine holds what the panel reads and drags
/// and the slot it fills (`ImmersiveMapDebugPanel`), at `package` access,
/// and this target fills it:
///
///     import ImmersiveMapDebug
///
///     ImmersiveMapView()
///         .debugPanel(.hud)
///
/// `Panel/` is the panel: the HUD views of each platform, the zoom badge,
/// the planners that turn a dragged control into settings, the settings
/// export, and the runtime that wires them to the engine
/// (`ImmersiveMapDebugOverlayRuntime`). Nothing here is reached by the
/// engine, and nothing here draws into the frame.
extension ImmersiveMapDebugPanel {
    /// The debug HUD: camera coordinates, renderer diagnostics and the
    /// bench controls, as host-view chrome over the map.
    public static var hud: ImmersiveMapDebugPanel {
        ImmersiveMapDebugPanel { host in
            ImmersiveMapDebugOverlayRuntime(host: host)
        }
    }
}
