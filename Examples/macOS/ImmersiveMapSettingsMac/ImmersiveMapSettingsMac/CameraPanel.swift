// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

/// Every limit on where the camera may go, live. The same fields are what the
/// `.zoomRange`, `.pitchRange` and `.bearingLimit` view modifiers write.
///
/// Two of these interact with the globe: the tilt ceiling and the bearing cap
/// are the *widest* the camera gets, and the globe still eases both in with
/// zoom (`globePitchUnlockZoom`, `globeBearingUnlockZoom`). A tilt floor above
/// the globe's own zoomed-out ceiling yields to it, which is visible here:
/// raise the floor, zoom out, and watch the camera level off anyway.
struct CameraPanel: View {
    @Binding var settings: ImmersiveMapSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow {
                // A minimum above the globe-to-flat transition window keeps the
                // map flat for good, which is how an app ships a flat-only map.
                ValueSlider("Zoom min",
                            value: $settings.camera.minimumZoom,
                            range: 0...12,
                            step: 0.5,
                            format: "%.1f",
                            width: 110)
                ValueSlider("Zoom max",
                            value: $settings.camera.maximumZoom,
                            range: 12...22,
                            step: 0.5,
                            format: "%.1f",
                            width: 110)

                Divider().frame(height: 20)

                ValueSlider("Tilt floor, deg",
                            value: minimumPitchDegrees,
                            range: 0...85,
                            step: 1,
                            format: "%.0f",
                            width: 110)
                ValueSlider("Tilt ceiling, deg",
                            value: maximumPitchDegrees,
                            range: 0...85,
                            step: 1,
                            format: "%.0f",
                            width: 110)
            }

            PanelRow {
                Toggle("Bearing cap", isOn: bearingCapEnabled)
                    .toggleStyle(.switch)
                ValueSlider("Cap, deg",
                            value: maximumBearingDegrees,
                            range: 0...180,
                            step: 5,
                            format: "%.0f",
                            width: 120)
                    .disabled(settings.camera.maximumAbsoluteBearing == nil)

                Divider().frame(height: 20)

                ValueSlider("Bearing unlock z",
                            value: $settings.camera.globeBearingUnlockZoom,
                            range: 0...10,
                            step: 0.5,
                            format: "%.1f",
                            width: 120)
                ValueSlider("Tilt unlock z",
                            value: $settings.camera.globePitchUnlockZoom,
                            range: 0...10,
                            step: 0.5,
                            format: "%.1f",
                            width: 120)

                Divider().frame(height: 20)

                // How fast a tilt drag tilts: multiples of the pitch range a
                // full-height drag sweeps (two fingers on touch, right-button
                // or Option-drag here).
                ValueSlider("Tilt speed",
                            value: tiltSensitivity,
                            range: 0.5...5,
                            step: 0.25,
                            format: "%.2f",
                            width: 120)
            }
        }
    }

    private var tiltSensitivity: Binding<Double> {
        Binding(get: { Double(settings.camera.tiltGestureSensitivity) },
                set: { settings.camera.tiltGestureSensitivity = Float($0) })
    }

    private var minimumPitchDegrees: Binding<Double> {
        degreesBinding($settings.camera.minimumPitch)
    }

    private var maximumPitchDegrees: Binding<Double> {
        degreesBinding($settings.camera.maximumPitch)
    }

    /// Off means unbounded (`nil`), not zero: a cap of zero locks the camera to
    /// north, which is also a valid thing to try here.
    private var bearingCapEnabled: Binding<Bool> {
        Binding(get: { settings.camera.maximumAbsoluteBearing != nil },
                set: { isEnabled in
                    settings.camera.maximumAbsoluteBearing = isEnabled ? .pi / 2 : nil
                })
    }

    private var maximumBearingDegrees: Binding<Double> {
        Binding(get: { Double(settings.camera.maximumAbsoluteBearing ?? .pi) * 180 / .pi },
                set: { settings.camera.maximumAbsoluteBearing = Float($0 * .pi / 180) })
    }

    private func degreesBinding(_ radians: Binding<Float>) -> Binding<Double> {
        Binding(get: { Double(radians.wrappedValue) * 180 / .pi },
                set: { radians.wrappedValue = Float($0 * .pi / 180) })
    }
}
