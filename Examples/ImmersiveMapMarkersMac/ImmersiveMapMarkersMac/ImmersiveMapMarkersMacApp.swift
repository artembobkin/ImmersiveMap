// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapMarkersMacApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap Markers") {
            MarkersScreen()
        }
        .defaultSize(width: 1100, height: 800)
    }
}

/// SwiftUI markers: arbitrary views anchored to geographic coordinates with the
/// `.markers(...)` modifier. The map reprojects them every rendered frame, in
/// flat mode, on the globe, and through the morph; past the globe horizon they
/// fade out and stop receiving input.
///
/// The controls show the three things that are easy to get wrong: which point of
/// the view touches the coordinate (`anchor`), whether the marker takes the
/// click or lets it through to the map, and what happens to marker state when
/// the backing collection changes.
private struct MarkersScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var places = DemoMarkerPlaces.all
    @State private var anchor: UnitPoint = .bottom
    @State private var usesCards = true
    @State private var pinnedIDs: Set<Int> = []

    var body: some View {
        ZStack(alignment: .bottom) {
            ImmersiveMapView()
                .camera(camera, position: Self.overview)
                .markers(places, coordinate: \.coordinate, anchor: anchor) { place in
                    if usesCards {
                        CityCardMarker(place: place,
                                       isPinned: pinnedIDs.contains(place.id)) {
                            togglePin(place.id)
                        }
                    } else {
                        PlaceDotMarker(place: place)
                    }
                }
                .enableCameraUIControls()
                .ignoresSafeArea()

            controls
                .padding(20)
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Anchor", selection: $anchor) {
                Text("Bottom").tag(UnitPoint.bottom)
                Text("Center").tag(UnitPoint.center)
                Text("Top").tag(UnitPoint.top)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Toggle("Interactive cards", isOn: $usesCards)
                .toggleStyle(.switch)

            Divider()
                .frame(height: 20)

            // Markers are plain SwiftUI data flow: mutate the collection and the
            // set updates on the next body evaluation. Views of surviving ids
            // keep their own @State, so a pinned card stays pinned.
            Button("Nudge east") {
                nudgePlaces()
            }
            Button("Drop last") {
                if places.count > 1 {
                    places.removeLast()
                }
            }
            Button("Reset") {
                places = DemoMarkerPlaces.all
                pinnedIDs = []
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func togglePin(_ id: Int) {
        if pinnedIDs.contains(id) {
            pinnedIDs.remove(id)
        } else {
            pinnedIDs.insert(id)
        }
    }

    /// A changed coordinate repositions the marker on the next frame without
    /// animation. For positions that should glide, interpolate them yourself or
    /// use avatar markers, whose `move` animates along a great circle.
    private func nudgePlaces() {
        places = places.map { place in
            var moved = place
            moved.coordinate = GeoCoordinate(latitude: place.coordinate.latitude,
                                             longitude: place.coordinate.longitude + 3)
            return moved
        }
    }

    private static let overview = ImmersiveMapCameraPosition(
        latitudeDegrees: 20,
        longitudeDegrees: 60,
        zoom: 1.7,
        bearing: 0,
        pitch: 0.08
    )
}
