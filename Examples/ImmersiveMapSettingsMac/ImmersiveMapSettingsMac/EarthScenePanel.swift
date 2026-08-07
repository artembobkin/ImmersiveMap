// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

/// The Earth scene: a visible sun, the day/night terminator across the globe,
/// and the starfield behind it. All of it lives on `settings.scene`;
/// `.earthScene(isEnabled:)` is the one-line shorthand for the whole package.
///
/// The sun position follows a wall date. `EarthSceneTimeMode.realtime` tracks
/// the clock; `.fixed(Date)` pins it, which is what the hour slider does, so
/// the terminator sweeps the planet as you drag.
struct EarthScenePanel: View {
    @Binding var settings: ImmersiveMapSettings
    @State private var hourOfDay: Double = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow {
                Toggle("Earth scene", isOn: $settings.scene.earth.isEnabled)
                    .toggleStyle(.switch)
                // Transparent space leaves everything outside the globe
                // unpainted, so what the app draws behind the map continues
                // around the planet. The whole starfield layer is skipped, the
                // visible sun with it.
                Toggle("Transparent space", isOn: $settings.scene.space.isTransparent)
                    .toggleStyle(.switch)
                Toggle("Follow the clock", isOn: followsRealtime)
                    .toggleStyle(.switch)
                    .disabled(settings.scene.earth.isEnabled == false)

                ValueSlider("Hour, UTC", value: fixedHour, range: 0...24, format: "%.1f")
                    .disabled(settings.scene.earth.isEnabled == false || isRealtime)
            }

            PanelRow {
                ValueSlider("Night brightness",
                            value: $settings.scene.earth.nightSideBrightness.asDouble,
                            range: 0...1)
                ValueSlider("Terminator fade",
                            value: $settings.scene.earth.terminatorFadeWidth.asDouble,
                            range: 0.01...0.5)
                ValueSlider("Sun glow",
                            value: $settings.scene.earth.sun.glowIntensity.asDouble,
                            range: 0...1)
                ValueSlider("Limb halo",
                            value: $settings.scene.earth.sun.limbHaloIntensity.asDouble,
                            range: 0...1)
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
            .disabled(settings.scene.earth.isEnabled == false)
        }
        // The panel is rebuilt every time the section comes back, so the hour
        // is recovered from the settings instead of snapping back to noon.
        .onAppear {
            guard case let .fixed(date) = settings.scene.earth.timeMode else {
                return
            }
            hourOfDay = date.timeIntervalSince(startOfUTCDay(for: date)) / 3600
        }
    }

    private var isRealtime: Bool {
        settings.scene.earth.timeMode == .realtime
    }

    private var followsRealtime: Binding<Bool> {
        Binding(get: { isRealtime },
                set: { settings.scene.earth.timeMode = $0 ? .realtime : .fixed(date(atHour: hourOfDay)) })
    }

    private var fixedHour: Binding<Double> {
        Binding(get: { hourOfDay },
                set: { newValue in
                    hourOfDay = newValue
                    settings.scene.earth.timeMode = .fixed(date(atHour: newValue))
                })
    }

    /// Today at the chosen UTC hour. The sun direction is derived from this
    /// date, so a fixed date makes the whole scene deterministic.
    ///
    /// The hour wraps: the slider reaches 24, which is midnight again rather
    /// than a date on the next day.
    private func date(atHour hour: Double) -> Date {
        let wrappedHour = hour.truncatingRemainder(dividingBy: 24)
        return startOfUTCDay(for: Date()).addingTimeInterval(wrappedHour * 3600)
    }

    private func startOfUTCDay(for date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.startOfDay(for: date)
    }
}
