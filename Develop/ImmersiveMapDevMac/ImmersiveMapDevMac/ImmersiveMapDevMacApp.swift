// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap
import ImmersiveMapDebug

@main
struct ImmersiveMapDevMacApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap Dev") {
            MapScreen()
        }
        // The window opens at a platform's size, so a screen recording of it
        // is ready to post.
        .windowFormat(.threadsVideo)
    }
}

private struct MapScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    /// The tile grid: the tiles tapped on the map are its selection.
    @State private var tileGrid = ImmersiveMapTileGridController()
    /// The selected tiles, shown in the panel.
    @State private var selectedTiles: [ImmersiveMapTileID] = []
    /// Why the last tap on a tile selected nothing, shown in the panel.
    @State private var tileRejection: String?
    /// Which zooms' tiles the grid shows, picked in the panel.
    @State private var tileGridZooms = TileGridZooms.city
    /// What is written inside a tile, picked in the panel.
    @State private var tileGridLabels = TileGridLabelChoice.zxy
    /// Whether a double click zooms the map, which makes a single click
    /// wait for it, switched in the panel.
    @State private var tileGridZoomsByDoubleClick = false
    /// The gesture that selects a tile, picked in the panel.
    @State private var tileGridGesture = ImmersiveMapSettings.TileGridSettings.SelectionGesture.doubleTap
    /// Whether one tile at a time is selected, switched in the panel.
    @State private var tileGridSelectsOne = false
    /// Whether a tap may select only round the city and twenty tiles at most.
    @State private var tileGridIsLimited = true

    /// A selection made from code: the tile of the grid's deepest zoom
    /// the camera looks at.
    private func selectTileUnderCamera() {
        guard let position = camera.currentCameraPosition() else { return }
        let coordinate = GeoCoordinate(latitude: position.latitudeDegrees, longitude: position.longitudeDegrees)
        tileGrid.select(ImmersiveMapTileID(containing: coordinate, zoom: tileGridZooms.range.upperBound))
    }

    /// The app's own text for a tile, in place of its numbers, when the
    /// panel asks for it.
    private func applyTileGridLabels() {
        if tileGridLabels == .custom {
            tileGrid.labelProvider = { tile in "tile \(tile.x % 100)-\(tile.y % 100)" }
        } else {
            tileGrid.labelProvider = nil
        }
    }

    var body: some View {
        ImmersiveMapView()
            .modelArchive(ImmersiveMapTilesService.modelArchiveURL)
            .cameraPosition(.city(.newYork))
            .cameraController(camera)
            // The tile grid: the tiles of the camera's zoom between 12 and
            // 15, a tap selecting or deselecting one. Twenty at most, and
            // only round the city: a tap past either is told in the panel.
            .tileGrid(tileGrid)
            // The double click zoom, for the grid selecting by another
            // gesture than the double click: off, a click selects at once.
            // While the grid selects by the double click it has that
            // gesture, and the map does not zoom by it either way.
            .doubleTapZoom(isEnabled: tileGridZoomsByDoubleClick)
            .tileGridSettings(zoomRange: tileGridZooms.range,
                              labelFormat: tileGridLabels.format,
                              selectionGesture: tileGridGesture,
                              selectionMode: tileGridSelectsOne ? .single : .multiple)
            .tileGridSelection(limit: tileGridIsLimited ? 20 : nil,
                               selectableBounds: tileGridIsLimited ? TileGridPanel.city : nil)
            .overlay(alignment: .topTrailing) {
                TileGridPanel(zooms: $tileGridZooms,
                              labels: $tileGridLabels,
                              isLimited: $tileGridIsLimited,
                              zoomsByDoubleClick: $tileGridZoomsByDoubleClick,
                              gesture: $tileGridGesture,
                              selectsOne: $tileGridSelectsOne,
                              selectedTiles: selectedTiles,
                              rejection: tileRejection,
                              selectUnderCamera: selectTileUnderCamera,
                              clear: { tileGrid.clearSelection() })
            }
            .onChange(of: tileGridLabels) {
                applyTileGridLabels()
            }
            .onAppear {
                // The callbacks are `@Sendable` and come on the main
                // thread: the state is set from the main actor.
                tileGrid.onSelectionChanged = { change in
                    Task { @MainActor in
                        selectedTiles = change.selectedTiles.sorted { ($0.zoom, $0.x, $0.y) < ($1.zoom, $1.x, $1.y) }
                        tileRejection = nil
                    }
                }
                tileGrid.onTapRejected = { rejection in
                    Task { @MainActor in
                        switch rejection.reason {
                        case let .limitReached(limit):
                            tileRejection = "\(rejection.tile): the limit of \(limit) tiles is reached"
                        case .outsideSelectableBounds:
                            tileRejection = "\(rejection.tile): outside the selectable area"
                        }
                    }
                }
            }
    }
}

/// The zooms the panel offers for the tile grid.
private enum TileGridZooms: String, CaseIterable, Identifiable {
    case city = "12...15, with the camera"
    case deepest = "15 alone"
    case globe = "0...5, for the globe"

    var id: String { rawValue }

    var range: ClosedRange<Int> {
        switch self {
        case .city: 12 ... 15
        case .deepest: 15 ... 15
        case .globe: 0 ... 5
        }
    }
}

/// What the panel offers to write inside a tile.
private enum TileGridLabelChoice: String, CaseIterable, Identifiable {
    case zxy = "z/x/y"
    case xyz = "x/y/z"
    case custom = "The app's text"
    case hidden = "None"

    var id: String { rawValue }

    /// The built-in format. The app's text comes from the controller's
    /// `labelProvider`, whatever the format.
    var format: ImmersiveMapSettings.TileGridSettings.LabelFormat {
        switch self {
        case .zxy, .custom: .zxy
        case .xyz: .xyz
        case .hidden: .hidden
        }
    }
}

/// The tile grid's example, in the corner: which tiles it shows, what a
/// tap may select, and what the controller holds, the selected tiles and
/// the last tap that selected nothing.
private struct TileGridPanel: View {
    /// The area tiles can be selected in: New York and its surroundings.
    static let city = ImmersiveMapGeoBounds(southWest: GeoCoordinate(latitude: 40.45, longitude: -74.30),
                                            northEast: GeoCoordinate(latitude: 40.95, longitude: -73.65))

    @Binding var zooms: TileGridZooms
    @Binding var labels: TileGridLabelChoice
    @Binding var isLimited: Bool
    @Binding var zoomsByDoubleClick: Bool
    @Binding var gesture: ImmersiveMapSettings.TileGridSettings.SelectionGesture
    @Binding var selectsOne: Bool
    let selectedTiles: [ImmersiveMapTileID]
    let rejection: String?
    let selectUnderCamera: () -> Void
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Zooms", selection: $zooms) {
                ForEach(TileGridZooms.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Text", selection: $labels) {
                ForEach(TileGridLabelChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Select by", selection: $gesture) {
                Text("Click").tag(ImmersiveMapSettings.TileGridSettings.SelectionGesture.tap)
                Text("Double click").tag(ImmersiveMapSettings.TileGridSettings.SelectionGesture.doubleTap)
                Text("Right click").tag(ImmersiveMapSettings.TileGridSettings.SelectionGesture.secondaryTap)
            }
            Toggle("One tile at a time", isOn: $selectsOne)
            Toggle("Only the city, 20 tiles at most", isOn: $isLimited)
            Toggle("Double click zooms (a click then waits)", isOn: $zoomsByDoubleClick)
            Divider()
            HStack {
                Text("Selected tiles: \(selectedTiles.count)")
                Spacer()
                Button("Under camera", action: selectUnderCamera)
                Button("Clear", action: clear)
                    .disabled(selectedTiles.isEmpty)
            }
            if selectedTiles.isEmpty {
                Text("Pick a tile on the map")
                    .foregroundStyle(.secondary)
            } else {
                Text(selectedTiles.prefix(8).map(\.description).joined(separator: "\n")
                     + (selectedTiles.count > 8 ? "\n..." : ""))
                    .font(.callout.monospacedDigit())
            }
            if let rejection {
                Text(rejection)
                    .foregroundStyle(.red)
            }
        }
        .font(.callout)
        .frame(width: 300, alignment: .leading)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }
}
