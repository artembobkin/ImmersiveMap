// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

struct DemoPlace: Identifiable {
    let id: Int
    let title: String
    var coordinate: GeoCoordinate
    let photoURL: URL
}

/// Cities for the SwiftUI card markers. Fiji exercises the antimeridian
/// (the unfurl wrap), Sydney and New York sit on opposite sides of the globe so
/// one of them is always behind the horizon and faded out.
enum DemoMarkerPlaces {
    static let all: [DemoPlace] = [
        DemoPlace(id: 1,
                  title: "New York",
                  coordinate: GeoCoordinate(latitude: 40.7128, longitude: -74.0060),
                  photoURL: photo("newyork,manhattan", lock: 7)),
        DemoPlace(id: 2,
                  title: "Paris",
                  coordinate: GeoCoordinate(latitude: 48.8566, longitude: 2.3522),
                  photoURL: photo("paris,eiffel", lock: 3)),
        DemoPlace(id: 3,
                  title: "Tokyo",
                  coordinate: GeoCoordinate(latitude: 35.6595, longitude: 139.7005),
                  photoURL: photo("tokyo,shibuya", lock: 11)),
        DemoPlace(id: 4,
                  title: "Sydney",
                  coordinate: GeoCoordinate(latitude: -33.8688, longitude: 151.2093),
                  photoURL: photo("sydney,opera", lock: 14)),
        DemoPlace(id: 5,
                  title: "Fiji",
                  coordinate: GeoCoordinate(latitude: -17.7134, longitude: 179.2000),
                  photoURL: photo("fiji,beach", lock: 5))
    ]

    /// loremflickr serves photos by keywords; lock pins a specific shot so the
    /// cards do not change between launches.
    private static func photo(_ keywords: String, lock: Int) -> URL {
        URL(string: "https://loremflickr.com/320/200/\(keywords)?lock=\(lock)")!
    }
}

/// City card: photo on top, name below, and a button that proves marker content
/// is fully interactive. Placed with anchor `.bottom`, the card's bottom edge
/// sits on the city coordinate.
struct CityCardMarker: View {
    let place: DemoPlace
    let isPinned: Bool
    let onPin: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AsyncImage(url: place.photoURL) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 132, height: 82)
            .clipped()

            HStack(spacing: 4) {
                Text(place.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                // A Button inside a marker receives the click itself: the map
                // does not pan or zoom from a gesture that starts here.
                Button(action: onPin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(.thinMaterial)
        }
        .frame(width: 132)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isPinned ? .yellow : .white.opacity(0.55), lineWidth: isPinned ? 1.5 : 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 7, y: 3)
    }
}

/// A decorative dot that never intercepts map gestures: the map pans and zooms
/// straight through it because its content disables hit testing.
struct PlaceDotMarker: View {
    let place: DemoPlace

    var body: some View {
        VStack(spacing: 2) {
            Text(place.title)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
        }
        .allowsHitTesting(false)
    }
}
