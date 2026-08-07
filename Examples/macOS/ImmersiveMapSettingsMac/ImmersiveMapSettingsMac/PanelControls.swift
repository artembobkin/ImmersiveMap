// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI

/// A slider for settings that reach the GPU as a uniform. Every intermediate
/// value is applied, which is what makes them feel live.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var format: String = "%.2f"
    var width: CGFloat = 140

    init(_ title: String,
         value: Binding<Double>,
         range: ClosedRange<Double>,
         step: Double? = nil,
         format: String = "%.2f",
         width: CGFloat = 140) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.format = format
        self.width = width
    }

    var body: some View {
        VStack(spacing: 2) {
            Text("\(title): \(value, specifier: format)")
                .font(.system(size: 11, design: .monospaced))
            if let step {
                Slider(value: $value, in: range, step: step)
                    .frame(width: width)
            } else {
                Slider(value: $value, in: range)
                    .frame(width: width)
            }
        }
    }
}

/// A slider whose value reaches the map only when the drag ends.
///
/// Some settings re-parse every visible tile and build a new renderer when
/// they change (labels, style colors, the star count). Binding one of those to
/// a live slider would run that work for every intermediate value, so the
/// dragged value stays local until the gesture is over.
struct DeferredValueSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var format: String = "%.2f"
    var width: CGFloat = 140
    let commit: (Double) -> Void

    @State private var draft: Double?

    init(_ title: String,
         value: Double,
         range: ClosedRange<Double>,
         step: Double? = nil,
         format: String = "%.2f",
         width: CGFloat = 140,
         commit: @escaping (Double) -> Void) {
        self.title = title
        self.value = value
        self.range = range
        self.step = step
        self.format = format
        self.width = width
        self.commit = commit
    }

    var body: some View {
        let shownValue = draft ?? value
        VStack(spacing: 2) {
            Text("\(title): \(shownValue, specifier: format)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(draft == nil ? Color.primary : Color.accentColor)
            slider(shownValue: shownValue)
        }
    }

    @ViewBuilder
    private func slider(shownValue: Double) -> some View {
        let binding = Binding(get: { shownValue }, set: { draft = $0 })
        if let step {
            Slider(value: binding, in: range, step: step, onEditingChanged: editingChanged)
                .frame(width: width)
        } else {
            Slider(value: binding, in: range, onEditingChanged: editingChanged)
                .frame(width: width)
        }
    }

    private func editingChanged(_ isEditing: Bool) {
        guard isEditing == false, let draft else {
            return
        }
        self.draft = nil
        commit(draft)
    }
}

/// A row of controls with the panel's own spacing, so panels do not repeat it.
struct PanelRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            content
        }
    }
}

/// Sliders work in `Double`; these settings are stored in the type the shader
/// or the engine wants.
extension Binding where Value == Float {
    var asDouble: Binding<Double> {
        Binding<Double>(get: { Double(wrappedValue) },
                        set: { wrappedValue = Float($0) })
    }
}

extension Binding where Value == Int {
    var asDouble: Binding<Double> {
        Binding<Double>(get: { Double(wrappedValue) },
                        set: { wrappedValue = Int($0) })
    }
}

/// Marks the controls under it as the expensive kind, next to the plan badge
/// that names what exactly they cost.
struct DeferredNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "clock.arrow.circlepath")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
