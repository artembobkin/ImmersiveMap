// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

/// MSDF text laid out and collided on the GPU, configured through
/// `settings.labels` (`.labelSettings(...)` on the view).
///
/// Language is the interesting one: it selects a different name field in the
/// vector tile and is part of the prepared-tile cache namespace
/// (`LabelLanguage.preparedTileCacheNamespaceKey`), so switching languages
/// re-prepares tiles rather than re-drawing the ones already in memory.
struct LabelsPanel: View {
    @Binding var settings: ImmersiveMapSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow {
                Picker("Language", selection: $settings.labels.language) {
                    Text("English").tag(ImmersiveMapSettings.LabelLanguage.english)
                    Text("Russian").tag(ImmersiveMapSettings.LabelLanguage.russian)
                    Text("French").tag(ImmersiveMapSettings.LabelLanguage.french)
                    Text("German").tag(ImmersiveMapSettings.LabelLanguage.german)
                    Text("Spanish").tag(ImmersiveMapSettings.LabelLanguage.spanish)
                    Text("Italian").tag(ImmersiveMapSettings.LabelLanguage.italian)
                    Text("Portuguese").tag(ImmersiveMapSettings.LabelLanguage.portuguese)
                    Text("Turkish").tag(ImmersiveMapSettings.LabelLanguage.turkish)
                    // Any BCP-47-ish code works, the presets are a convenience.
                    Text("Japanese (ja)").tag(ImmersiveMapSettings.LabelLanguage("ja"))
                }
                .frame(width: 210)

                Picker("Fallback", selection: $settings.labels.fallbackPolicy) {
                    Text("International").tag(ImmersiveMapSettings.LabelFallbackPolicy.international)
                    Text("Local first").tag(ImmersiveMapSettings.LabelFallbackPolicy.localFirst)
                }
                .pickerStyle(.segmented)
                .frame(width: 290)

                Toggle("House numbers", isOn: $settings.labels.houseNumbers.enabled)
                    .toggleStyle(.switch)
            }

            PanelRow {
                // Zoom thresholds are integers, so the sliders step in whole
                // levels: a displayed 12.9 that quietly applies 12 is a worse
                // demo than a slider that only offers 12 and 13.
                DeferredValueSlider("Settlements up to z",
                                    value: Double(settings.labels.settlementVisibility.cityMaximumZoom),
                                    range: 4...18,
                                    step: 1,
                                    format: "%.0f") { newValue in
                    // A settlement label is drawn up to its own maximum zoom and
                    // then gives the screen to street and landmark labels.
                    let zoom = Int(newValue)
                    settings.labels.settlementVisibility =
                        ImmersiveMapSettings.LabelSettings.SettlementVisibilitySettings(capitalMaximumZoom: zoom,
                                                                                        cityMaximumZoom: zoom,
                                                                                        smallSettlementMaximumZoom: zoom)
                }

                DeferredValueSlider("Landmarks from z",
                                    value: Double(settings.labels.landmarks.minimumZoom),
                                    range: 10...18,
                                    step: 1,
                                    format: "%.0f") { newValue in
                    settings.labels.landmarks.minimumZoom = Int(newValue)
                }

                DeferredValueSlider("Numbers from z",
                                    value: Double(settings.labels.houseNumbers.minimumZoom),
                                    range: 12...19,
                                    step: 1,
                                    format: "%.0f") { newValue in
                    settings.labels.houseNumbers.minimumZoom = Int(newValue)
                }

                DeferredValueSlider("Fade, s",
                                    value: settings.labels.base.fadeInSeconds,
                                    range: 0...1.5) { newValue in
                    settings.labels.base.fadeInSeconds = newValue
                    settings.labels.base.fadeOutSeconds = newValue
                }
            }

            PanelRow {
                // Points, not pixels: the cell keeps its perceived size on every
                // display, so a dense screen does not quietly pack more labels
                // into the same physical area.
                DeferredValueSlider("Collision grid, pt",
                                    value: Double(settings.labels.base.gridCellSizePoints),
                                    range: 8...48,
                                    step: 1,
                                    format: "%.0f") { newValue in
                    settings.labels.base.gridCellSizePoints = Float(newValue)
                    settings.labels.road.gridCellSizePoints = Float(newValue)
                }
            }

            DeferredNote(text: "Label sliders commit when you let go: every value re-prepares the visible tiles.")
        }
    }
}
