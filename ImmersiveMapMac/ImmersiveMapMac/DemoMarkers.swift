// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

struct DemoPlace: Identifiable {
    let id: Int
    let title: String
    let coordinate: GeoCoordinate
    let photoURL: URL
}

/// Города для SwiftUI-маркеров-карточек. Намеренно НЕ пересекаются с
/// городами аватаров (DemoAvatars): в одном месте либо карточка, либо
/// аватары. Фиджи заодно проверяет антимеридиан (wrap развёртки).
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
        DemoPlace(id: 4,
                  title: "Sydney",
                  coordinate: GeoCoordinate(latitude: -33.8688, longitude: 151.2093),
                  photoURL: photo("sydney,opera", lock: 14)),
        DemoPlace(id: 5,
                  title: "Fiji",
                  coordinate: GeoCoordinate(latitude: -17.7134, longitude: 179.2000),
                  photoURL: photo("fiji,beach", lock: 5))
    ]

    /// loremflickr отдаёт фото по ключевым словам, lock фиксирует конкретный
    /// кадр, чтобы карточки не менялись между запусками (важно для промо).
    private static func photo(_ keywords: String, lock: Int) -> URL {
        URL(string: "https://loremflickr.com/320/200/\(keywords)?lock=\(lock)")!
    }
}

/// Карточка города: фото сверху, название снизу. Ставится якорем .bottom,
/// нижняя кромка карточки стоит на координате города.
struct CityCardMarker: View {
    let place: DemoPlace

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

            Text(place.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial)
        }
        .frame(width: 132)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.55), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 7, y: 3)
    }
}

/// Аватар-маркеры со случайными портретами (pravatar.cc): «толпа» на улицах
/// Токио и Дубая попадает в кадр во время орбит кино-тура, несколько точек
/// по миру видны на глобусе. Города аватаров намеренно не пересекаются с
/// городами карточек (DemoMarkerPlaces). До загрузки портрета показывается
/// номерная заглушка AvatarMarkerImageFactory.
@MainActor
enum DemoAvatars {
    static func populate(_ controller: ImmersiveMapAvatarsController) {
        var markers: [AvatarMarker] = []
        var nextID: UInt64 = 1

        func add(lat: Double,
                 lon: Double,
                 image: Int,
                 battery: Int? = nil,
                 speed: Int? = nil) {
            markers.append(AvatarMarker(id: nextID,
                                        latitude: lat,
                                        longitude: lon,
                                        imageURL: URL(string: "https://i.pravatar.cc/256?img=\(image)")!,
                                        placeholder: AvatarMarkerImageFactory.number(Int(nextID)),
                                        batteryPercent: battery,
                                        speedKilometersPerHour: speed))
            nextID += 1
        }

        // Толпа вокруг улиц Токио (вид с турнтейбла кино-тура).
        let tokyo = (lat: 35.6595, lon: 139.7005)
        add(lat: tokyo.lat + 0.0012, lon: tokyo.lon + 0.0018, image: 11, battery: 84)
        add(lat: tokyo.lat - 0.0016, lon: tokyo.lon + 0.0009, image: 12, speed: 14)
        add(lat: tokyo.lat + 0.0007, lon: tokyo.lon - 0.0021, image: 13, battery: 47)
        add(lat: tokyo.lat - 0.0011, lon: tokyo.lon - 0.0013, image: 14)
        add(lat: tokyo.lat + 0.0024, lon: tokyo.lon - 0.0004, image: 15, battery: 92, speed: 5)
        add(lat: tokyo.lat - 0.0025, lon: tokyo.lon + 0.0022, image: 16)
        add(lat: tokyo.lat + 0.0003, lon: tokyo.lon + 0.0032, image: 17, battery: 61)
        add(lat: tokyo.lat - 0.0005, lon: tokyo.lon - 0.0034, image: 18, speed: 32)

        // Толпа вокруг Дубая.
        let dubai = (lat: 25.1972, lon: 55.2744)
        add(lat: dubai.lat + 0.0014, lon: dubai.lon + 0.0011, image: 21, battery: 73)
        add(lat: dubai.lat - 0.0009, lon: dubai.lon + 0.0024, image: 22)
        add(lat: dubai.lat + 0.0021, lon: dubai.lon - 0.0008, image: 23, speed: 41)
        add(lat: dubai.lat - 0.0019, lon: dubai.lon - 0.0017, image: 24, battery: 28)
        add(lat: dubai.lat + 0.0006, lon: dubai.lon - 0.0029, image: 25)
        add(lat: dubai.lat - 0.0002, lon: dubai.lon + 0.0035, image: 26, battery: 55, speed: 9)
        add(lat: dubai.lat + 0.0028, lon: dubai.lon + 0.0002, image: 27)
        add(lat: dubai.lat - 0.0027, lon: dubai.lon - 0.0003, image: 28, speed: 23)

        // По миру: видны на глобусе в начале и конце лупа.
        add(lat: 55.7558, lon: 37.6173, image: 31, battery: 66)    // Москва
        add(lat: -22.9068, lon: -43.1729, image: 34, speed: 17)    // Рио
        add(lat: 37.7749, lon: -122.4194, image: 35, battery: 39)  // Сан-Франциско
        add(lat: 19.4326, lon: -99.1332, image: 36)                // Мехико

        controller.set(markers)
    }
}
