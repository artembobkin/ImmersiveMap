// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

/// What to turn on while measuring, and the two caches that decide how much of
/// a revisited area is free.
///
/// Rendering is on demand: the display link is paused until something asks for
/// a frame, so an idle map costs nothing. `forceContinuousRendering` takes that
/// away and draws every vsync, which is what you want under a GPU capture and
/// never in production.
///
/// The caches sit on top of each other. `urlCacheEnabled` keeps the raw tile
/// bytes, `preparedTileCacheEnabled` keeps them parsed and tessellated, and the
/// memory cache keeps them as GPU buffers. Turning one off is how you measure
/// the cost of the stage below it.
struct DiagnosticsPanel: View {
    @Binding var settings: ImmersiveMapSettings

    private static let bytesPerMebibyte = 1_024 * 1_024

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow {
                Toggle("Debug panel", isOn: $settings.debug.enableDebugPanel)
                    .toggleStyle(.switch)
                Toggle("FXAA", isOn: $settings.postProcessing.fxaaEnabled)
                    .toggleStyle(.switch)
                Toggle("Continuous rendering", isOn: $settings.renderLoop.forceContinuousRendering)
                    .toggleStyle(.switch)

                ValueSlider("Interaction fps",
                            value: $settings.renderLoop.interactionFramesPerSecond.asDouble,
                            range: 15...120,
                            step: 15,
                            format: "%.0f")
                ValueSlider("Tile zoom cap",
                            value: $settings.tiles.coverage.maximumZoomLevel.asDouble,
                            range: 6...14,
                            step: 1,
                            format: "%.0f")
            }

            PanelRow {
                Toggle("Raw tile cache", isOn: $settings.tiles.cache.urlCacheEnabled)
                    .toggleStyle(.switch)
                Toggle("Prepared tile cache", isOn: $settings.tiles.cache.preparedTileCacheEnabled)
                    .toggleStyle(.switch)
                Toggle("Compress prepared tiles", isOn: $settings.tiles.cache.preparedDiskCompressionEnabled)
                    .toggleStyle(.switch)
                    .disabled(settings.tiles.cache.preparedTileCacheEnabled == false)

                DeferredValueSlider("GPU tile cache, MiB",
                                    value: Double(settings.tiles.cache.memoryCacheSizeInBytes / Self.bytesPerMebibyte),
                                    range: 64...1024,
                                    step: 64,
                                    format: "%.0f",
                                    width: 160) { newValue in
                    settings.tiles.cache.memoryCacheSizeInBytes = Int(newValue) * Self.bytesPerMebibyte
                }
            }

            DeferredNote(text: "Cache switches rebuild the tile loader, so tiles on screen are fetched again.")
        }
    }
}
