// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

/// The streetscape: `settings.tiles.streetscape`. The toggle is the whole
/// feature for the hosted service, which implies its own archive; the
/// template field is for a custom tile source with a streetscape archive of
/// its own, and is left empty here on purpose.
struct StreetscapePanel: View {
    @Binding var settings: ImmersiveMapSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow {
                Toggle("Streetscape", isOn: $settings.tiles.streetscape.isEnabled)
                    .toggleStyle(.switch)
                TextField("Streetscape tile URL template (custom sources only)",
                          text: Binding(
                              get: { settings.tiles.streetscape.tileURLTemplate ?? "" },
                              set: { settings.tiles.streetscape.tileURLTemplate = $0.isEmpty ? nil : $0 }
                          ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 520)
            }
            Text("Two requests per tile from z15, merged before parsing. A change re-prepares every tile.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
