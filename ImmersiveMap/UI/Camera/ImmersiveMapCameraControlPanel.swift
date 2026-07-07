// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

#if canImport(SwiftUI)
import SwiftUI

extension View {
    func immersiveMapCameraControlsOverlay(camera: ImmersiveMapCameraController,
                                           initialCameraPosition: ImmersiveMapCameraPosition = ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                                                                                                          longitudeDegrees: 0,
                                                                                                                          zoom: 0),
                                           maximumPitch: Float = ImmersiveMapSettings.default.camera.maximumPitch) -> some View {
        modifier(ImmersiveMapCameraControlsModifier(camera: camera,
                                                    initialCameraPosition: initialCameraPosition,
                                                    maximumPitch: maximumPitch))
    }
}

private struct ImmersiveMapCameraControlsModifier: ViewModifier {
    let camera: ImmersiveMapCameraController
    let maximumPitch: Float
    @State private var liveCameraPosition: ImmersiveMapCameraPosition
    @State private var liveCameraSnapshot: ImmersiveMapCameraSnapshot?

    init(camera: ImmersiveMapCameraController,
         initialCameraPosition: ImmersiveMapCameraPosition,
         maximumPitch: Float) {
        self.camera = camera
        self.maximumPitch = maximumPitch
        _liveCameraPosition = State(initialValue: initialCameraPosition)
    }

    func body(content: Content) -> some View {
        ZStack {
            content

            ImmersiveMapCameraControlPanel(
                cameraSnapshot: liveCameraSnapshot ?? fallbackCameraSnapshot
            ) { nextPosition in
                let cameraSnapshot = liveCameraSnapshot ?? fallbackCameraSnapshot
                let constrainedPosition = cameraSnapshot.clampedPosition(nextPosition)
                liveCameraPosition = constrainedPosition
                camera.setCameraAngleTarget(bearingRadians: constrainedPosition.bearing,
                                            pitchRadians: constrainedPosition.pitch)
            }
            .padding(.trailing, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .onAppear {
            camera.onCameraSnapshotChanged = { snapshot in
                Task { @MainActor in
                    liveCameraSnapshot = snapshot
                    liveCameraPosition = snapshot.position
                }
            }
            if let currentSnapshot = camera.currentCameraSnapshot() {
                liveCameraSnapshot = currentSnapshot
                liveCameraPosition = currentSnapshot.position
            }
        }
        .onDisappear {
            camera.onCameraSnapshotChanged = nil
        }
    }

    private var fallbackCameraSnapshot: ImmersiveMapCameraSnapshot {
        ImmersiveMapCameraSnapshot(
            position: liveCameraPosition,
            bearingLimits: ImmersiveMapCameraBearingLimits(maximumAbsoluteBearing: .pi),
            pitchLimits: ImmersiveMapCameraAngleLimits(minimum: 0, maximum: maximumPitch),
            isSphericalSurfaceActive: false
        )
    }
}

public struct ImmersiveMapCameraControlPanel: View {
    private let cameraSnapshot: ImmersiveMapCameraSnapshot
    private let onChange: (ImmersiveMapCameraPosition) -> Void
    @State private var draftBearingDegrees: Double?
    @State private var draftPitchDegrees: Double?
    @State private var isScrubbing = false

    public init(cameraSnapshot: ImmersiveMapCameraSnapshot,
                onChange: @escaping (ImmersiveMapCameraPosition) -> Void) {
        self.cameraSnapshot = cameraSnapshot
        self.onChange = onChange
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 15, weight: .semibold))
                Text("Camera")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            CameraControlSection(title: "Rotate", value: CameraControlMath.formattedDegrees(displayedBearingDegrees)) {
                HStack(spacing: 8) {
                    CameraIconButton(systemName: "rotate.left",
                                     help: "Rotate left 15 deg") {
                        adjustBearing(byDegrees: -15)
                    }

                    CameraIconButton(systemName: "location.north.line",
                                     help: "Reset north") {
                        setBearing(degrees: 0)
                    }

                    CameraIconButton(systemName: "rotate.right",
                                     help: "Rotate right 15 deg") {
                        adjustBearing(byDegrees: 15)
                    }
                }

                CameraScrubSlider(value: bearingBinding,
                                  range: bearingRangeDegrees,
                                  step: 0,
                                  onEditingChanged: { isScrubbing = $0 })
            }

            Divider()
                .overlay(.white.opacity(0.2))

            CameraControlSection(title: "Tilt", value: CameraControlMath.formattedDegrees(displayedPitchDegrees)) {
                HStack(spacing: 8) {
                    CameraIconButton(systemName: "chevron.down",
                                     help: "Tilt down 5 deg") {
                        adjustPitch(byDegrees: -5)
                    }

                    CameraIconButton(systemName: "viewfinder",
                                     help: "Reset tilt") {
                        setPitch(degrees: 0)
                    }

                    CameraIconButton(systemName: "chevron.up",
                                     help: "Tilt up 5 deg") {
                        adjustPitch(byDegrees: 5)
                    }
                }

                CameraScrubSlider(value: pitchBinding,
                                  range: pitchRangeDegrees,
                                  step: 0,
                                  onEditingChanged: { isScrubbing = $0 })
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 248)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 8)
        .onChange(of: cameraPosition) { _ in
            // Во время скраба камера сглаженно догоняет цель — ползунок держим на цели (draft),
            // иначе follow-лаг камеры дёргал бы thumb назад на каждый кадр. Синк с фактическим
            // углом возобновляем после отпускания.
            guard isScrubbing == false else {
                return
            }
            draftBearingDegrees = nil
            draftPitchDegrees = nil
        }
    }

    private var cameraPosition: ImmersiveMapCameraPosition {
        cameraSnapshot.position
    }

    private var bearingDegrees: Double {
        CameraControlMath.degrees(fromRadians: Double(cameraPosition.bearing))
    }

    private var pitchDegrees: Double {
        CameraControlMath.degrees(fromRadians: Double(cameraPosition.pitch))
    }

    private var displayedBearingDegrees: Double {
        draftBearingDegrees ?? bearingDegrees
    }

    private var displayedPitchDegrees: Double {
        draftPitchDegrees ?? pitchDegrees
    }

    private var bearingRangeDegrees: ClosedRange<Double> {
        let minimum = CameraControlMath.degrees(fromRadians: Double(cameraSnapshot.bearingLimits.minimum))
        let maximum = CameraControlMath.degrees(fromRadians: Double(cameraSnapshot.bearingLimits.maximum))
        if minimum <= -180, maximum >= 180 {
            return -180...179
        }
        return minimum...maximum
    }

    private var pitchRangeDegrees: ClosedRange<Double> {
        let minimum = Double(cameraSnapshot.pitchLimits.minimum) * 180 / .pi
        let maximum = Double(cameraSnapshot.pitchLimits.maximum) * 180 / .pi
        return minimum...maximum
    }

    private var bearingBinding: Binding<Double> {
        Binding {
            displayedBearingDegrees
        } set: { newValue in
            let clampedValue = clampedBearingDegrees(newValue)
            draftBearingDegrees = clampedValue
            applyCameraUpdate(bearingDegrees: clampedValue,
                              pitchDegrees: displayedPitchDegrees)
        }
    }

    private var pitchBinding: Binding<Double> {
        Binding {
            displayedPitchDegrees
        } set: { newValue in
            let clampedValue = CameraControlMath.clampedDegrees(newValue, range: pitchRangeDegrees)
            draftPitchDegrees = clampedValue
            applyCameraUpdate(bearingDegrees: displayedBearingDegrees,
                              pitchDegrees: clampedValue)
        }
    }

    private func adjustBearing(byDegrees delta: Double) {
        setBearing(degrees: displayedBearingDegrees + delta)
    }

    private func setBearing(degrees: Double) {
        let clampedValue = clampedBearingDegrees(degrees)
        draftBearingDegrees = clampedValue
        applyCameraUpdate(bearingDegrees: clampedValue,
                          pitchDegrees: displayedPitchDegrees)
    }

    private func adjustPitch(byDegrees delta: Double) {
        setPitch(degrees: displayedPitchDegrees + delta)
    }

    private func setPitch(degrees: Double) {
        let clampedValue = CameraControlMath.clampedDegrees(degrees, range: pitchRangeDegrees)
        draftPitchDegrees = clampedValue
        applyCameraUpdate(bearingDegrees: displayedBearingDegrees,
                          pitchDegrees: clampedValue)
    }

    private func clampedBearingDegrees(_ degrees: Double) -> Double {
        CameraControlMath.clampedDegrees(CameraControlMath.normalizedDegrees(degrees),
                                         range: bearingRangeDegrees)
    }

    private func applyCameraUpdate(bearingDegrees: Double, pitchDegrees: Double) {
        let requestedPosition = cameraPosition.withCameraAngles(bearingDegrees: bearingDegrees,
                                                                pitchDegrees: pitchDegrees)
        onChange(requestedPosition)
    }
}

private struct CameraControlSection<Content: View>: View {
    let title: String
    let value: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
            }

            content
        }
    }
}

private struct CameraIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct CameraScrubSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var onEditingChanged: (Bool) -> Void = { _ in }

    private let thumbSize: CGFloat = 22
    private let trackHeight: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = max(1, proxy.size.width - thumbSize)
            let progress = progress(for: value)
            let thumbCenterX = thumbSize / 2 + trackWidth * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.14))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(Color(red: 0.02, green: 0.55, blue: 0.95))
                    .frame(width: max(thumbCenterX, thumbSize / 2), height: trackHeight)

                Circle()
                    .fill(.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.22), radius: 4, x: 0, y: 2)
                    .offset(x: thumbCenterX - thumbSize / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onEditingChanged(true)
                        value = steppedValue(for: gesture.location.x,
                                             trackWidth: trackWidth)
                    }
                    .onEnded { gesture in
                        value = steppedValue(for: gesture.location.x,
                                             trackWidth: trackWidth)
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera slider")
        .accessibilityValue(CameraControlMath.formattedDegrees(value))
    }

    private func progress(for value: Double) -> CGFloat {
        let lower = range.lowerBound
        let upper = range.upperBound
        guard upper > lower else {
            return 0
        }

        let clampedValue = min(max(value, lower), upper)
        return CGFloat((clampedValue - lower) / (upper - lower))
    }

    private func steppedValue(for locationX: CGFloat, trackWidth: CGFloat) -> Double {
        let rawProgress = Double(min(max(0, locationX - thumbSize / 2), trackWidth) / trackWidth)
        let rawValue = range.lowerBound + (range.upperBound - range.lowerBound) * rawProgress
        let snappedValue = step > 0 ? (rawValue / step).rounded() * step : rawValue
        return min(max(snappedValue, range.lowerBound), range.upperBound)
    }
}

private enum CameraControlMath {
    static func degrees(fromRadians radians: Double) -> Double {
        let degrees = radians * 180 / .pi
        return normalizedDegrees(degrees)
    }

    static func radians(fromDegrees degrees: Double) -> Float {
        Float(normalizedDegrees(degrees) * .pi / 180)
    }

    static func formattedDegrees(_ degrees: Double) -> String {
        "\(Int(degrees.rounded())) deg"
    }

    static func clampedDegrees(_ degrees: Double, range: ClosedRange<Double>) -> Double {
        min(max(degrees, range.lowerBound), range.upperBound)
    }

    static func normalizedDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 {
            value -= 360
        } else if value < -180 {
            value += 360
        }
        return value
    }
}

private extension ImmersiveMapCameraPosition {
    func withCameraAngles(bearingDegrees: Double,
                          pitchDegrees: Double) -> ImmersiveMapCameraPosition {
        ImmersiveMapCameraPosition(
            latitudeDegrees: latitudeDegrees,
            longitudeDegrees: longitudeDegrees,
            zoom: zoom,
            bearing: CameraControlMath.radians(fromDegrees: bearingDegrees),
            pitch: Float(pitchDegrees * .pi / 180)
        )
    }
}
#endif
