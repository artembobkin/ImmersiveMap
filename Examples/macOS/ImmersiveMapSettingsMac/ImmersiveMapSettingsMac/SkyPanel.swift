// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

/// The sky of the globe presentation: the space background and the starfield
/// behind the planet. Both live on `settings.scene`; transparent space leaves
/// everything outside the globe unpainted, so what the app draws behind the
/// map continues around the planet.
struct SkyPanel: View {
    @Binding var settings: ImmersiveMapSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow {
                Toggle("Transparent space", isOn: $settings.scene.space.isTransparent)
                    .toggleStyle(.switch)
                // The starfield is a GPU buffer built once at startup, not a
                // uniform: a new count means new geometry and a new renderer.
                DeferredValueSlider("Stars",
                                    value: Double(settings.scene.starfield.starCount),
                                    range: 0...8000,
                                    step: 100,
                                    format: "%.0f") { newValue in
                    settings.scene.starfield.starCount = Int(newValue)
                }
            }
        }
    }
}
