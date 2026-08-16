// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapSettingsMacApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap Settings") {
            SettingsPlaygroundScreen()
        }
        .defaultSize(width: 1240, height: 860)
    }
}

/// Everything an app can change about a map that is already on screen.
///
/// `ImmersiveMapSettings` is a single value and `ImmersiveMapView(settings:)`
/// takes it whole, so this app keeps one `@State` copy and each sidebar panel
/// writes into a different branch of it. The `.labelSettings(...)`-style
/// modifiers used by the other examples do exactly the same thing one branch
/// at a time.
///
/// Fields do not cost the same. `ImmersiveMapSettingsApplicationPlanner` is the
/// engine's own answer to "what will this change do", and the badge in the top
/// trailing corner reports its verdict for the last edit: a uniform written
/// into the next frame, or re-parsing every visible tile and building a new
/// renderer. That is why panels commit their expensive sliders when the drag
/// ends instead of on every value.
private struct SettingsPlaygroundScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var settings = ImmersiveMapSettings.default
        .tileURLTemplate(hostedTileTemplate, headers: hostedTileHeaders())
    @State private var selection: PlaygroundSection? = .labels
    @State private var lastPlan: ImmersiveMapSettingsApplicationPlan?

    private var section: PlaygroundSection {
        selection ?? .labels
    }

    var body: some View {
        NavigationSplitView {
            List(PlaygroundSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            mapArea
        }
        .onChange(of: selection) { _, _ in
            camera.fly(to: section.cameraPosition,
                       options: CameraFlightOptions(duration: 2.2,
                                                    routeStyle: .greatCircle,
                                                    altitudeStyle: .overviewFirst))
        }
        .onChange(of: settings) { oldSettings, newSettings in
            lastPlan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings,
                                                                       to: newSettings)
        }
    }

    private var mapArea: some View {
        ZStack(alignment: .bottom) {
            // Only ever seen through the map: the Earth scene section can make
            // space transparent, and then whatever the app draws behind the map
            // continues around the globe.
            LinearGradient(colors: [.indigo, .purple, .orange],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ImmersiveMapView(settings: settings)
                .camera(camera)
                .enableCameraUIControls()
                .ignoresSafeArea()

            applyPlanBadge
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            panel
                .padding(20)
        }
        .navigationTitle(section.title)
        // The opening position is placed imperatively instead of declared with
        // `.camera(camera, position:)`. A declared position is reapplied on
        // every SwiftUI update, and this app both flies the camera between
        // sections and re-renders on every settings edit, so the two would
        // fight: the first slider move after a flight would snap the map back
        // to where the declaration points. Commands queue up in the controller
        // until the view attaches, so this is safe before the first frame.
        .onAppear {
            camera.jump(to: section.cameraPosition)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // An exact width, not `maxWidth` and not `idealWidth`. The window
            // asks its content for a size before it has a width of its own, and
            // under that query a text with an upper bound only is free to wrap
            // one word per line: the paragraph reports a column some 2500 points
            // tall, the window opens taller than the display, and this panel
            // ends up below its bottom edge with no way to reach it. A width the
            // text can measure against keeps the paragraph five lines.
            Text(section.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 640, alignment: .leading)

            sectionControls
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var sectionControls: some View {
        switch section {
        case .labels:
            LabelsPanel(settings: $settings)
        case .buildings:
            BuildingsPanel(settings: $settings)
        case .earthScene:
            EarthScenePanel(settings: $settings)
        case .style:
            StylePanel(settings: $settings)
        case .presentation:
            PresentationPanel(settings: $settings, camera: camera)
        case .camera:
            CameraPanel(settings: $settings)
        case .diagnostics:
            DiagnosticsPanel(settings: $settings)
        }
    }

    /// The engine's plan for the last edit. `liveApply` is a uniform the next
    /// frame reads; `invalidateCaches` drops the tile caches;
    /// `rebuildPreparedData` re-parses and re-tessellates every tile;
    /// `recreateRenderer` throws the renderer away and builds a new one.
    @ViewBuilder
    private var applyPlanBadge: some View {
        if let lastPlan, lastPlan.actions.isEmpty == false {
            VStack(alignment: .leading, spacing: 5) {
                Text("Applying the last change")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(orderedActions(of: lastPlan), id: \.self) { action in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(action == .liveApply ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(action.rawValue)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// Cheapest first, so the badge reads as an escalation.
    private func orderedActions(of plan: ImmersiveMapSettingsApplicationPlan) -> [ImmersiveMapSettingsApplyAction] {
        ImmersiveMapSettingsApplyAction.allCases.filter { plan.actions.contains($0) }
    }
}

/// The hosted tile endpoint, written as the one-line URL template. The API key
/// is read from the local environment (`IMMERSIVEMAP_API_KEY`) so it stays on
/// this machine and never lands in the repository; without it the map renders
/// on the shared anonymous pool.
private let hostedTileTemplate = "https://tiles.immersivemap.dev/{z}/{x}/{y}.mvt"

private func hostedTileHeaders() -> [String: String] {
    guard let key = ProcessInfo.processInfo.environment["IMMERSIVEMAP_API_KEY"],
          key.isEmpty == false else {
        return [:]
    }
    return ["Authorization": "Bearer \(key)"]
}
