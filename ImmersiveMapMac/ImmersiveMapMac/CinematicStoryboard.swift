// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// Раскадровка демо-ролика: глобус, облёт, морфинг в город, орбита, луп.
enum CinematicStoryboard {
    /// Точка отправления и точка возврата лупа (глобус целиком).
    static let overview = ImmersiveMapCameraPosition(
        latitudeDegrees: 25,
        longitudeDegrees: -30,
        zoom: 1.7,
        bearing: 0,
        pitch: 0.08
    )

    // Герои кадров: плотная застройка, узнаваемые силуэты.
    private static let tokyo = (lat: 35.6595, lon: 139.7005)
    private static let dubai = (lat: 25.1972, lon: 55.2744)

    static func makeShots() -> [ImmersiveMapCameraTourShot] {
        var shots: [ImmersiveMapCameraTourShot] = []

        // 1. Разворот по большой дуге к Токио: глобус заметно вращается.
        shots.append(ImmersiveMapCameraTourShot(
            position: ImmersiveMapCameraPosition(latitudeDegrees: tokyo.lat,
                                                 longitudeDegrees: tokyo.lon,
                                                 zoom: 4.0, bearing: 0, pitch: 0.2),
            options: CameraFlightOptions(duration: 3.8, routeStyle: .greatCircle, altitudeStyle: .direct),
            holdAfter: 0.5
        ))

        // Окно морфа глобус <-> плоскость на широте Токио: z6.0..z7.3
        // (automaticTransitionStartZoom 6.0, span 1.0 плюс широтная добавка
        // log2(1/cos(35.7°)) ~= 0.3). Чтобы морфинг был виден под большим
        // tilt, наклон набирается ДО окна, а само окно пересекается медленным
        // отдельным перелётом с постоянным pitch.

        // 2. Наклон ещё на глобусе, чуть ниже окна морфа: 1.28 рад (~73°),
        // почти максимум камеры (75°).
        let tokyoPreTilt = ImmersiveMapCameraPosition(latitudeDegrees: tokyo.lat,
                                                      longitudeDegrees: tokyo.lon,
                                                      zoom: 5.6, bearing: 0.25, pitch: 1.28)
        shots.append(ImmersiveMapCameraTourShot(
            position: tokyoPreTilt,
            options: CameraFlightOptions(duration: 2.2, routeStyle: .automatic, altitudeStyle: .direct),
            holdAfter: 0.2
        ))

        // 3. Медленный проход сквозь всё окно морфа под полным наклоном:
        // глобус разворачивается в плоскость прямо в перспективе
        // (ключевой кадр промо).
        let tokyoMorphIn = ImmersiveMapCameraPosition(latitudeDegrees: tokyo.lat,
                                                      longitudeDegrees: tokyo.lon,
                                                      zoom: 7.6, bearing: 0.45, pitch: 1.28)
        shots.append(ImmersiveMapCameraTourShot(
            position: tokyoMorphIn,
            options: CameraFlightOptions(duration: 5.0, routeStyle: .automatic, altitudeStyle: .direct),
            holdAfter: 0.4
        ))

        // 4. Пикирование на улицы: поднимаются здания.
        let tokyoStreet = ImmersiveMapCameraPosition(latitudeDegrees: tokyo.lat,
                                                     longitudeDegrees: tokyo.lon,
                                                     zoom: 16.7, bearing: 0.55, pitch: 1.02)
        shots.append(ImmersiveMapCameraTourShot(
            position: tokyoStreet,
            options: CameraFlightOptions(duration: 2.8, routeStyle: .automatic, altitudeStyle: .direct),
            holdAfter: 0.7
        ))

        // 5. Turntable вокруг застройки Токио.
        shots.append(contentsOf: orbit(base: tokyoStreet, segments: 3, perSegmentDuration: 2.3))

        // 6. Подъём из улиц обратно к верхней кромке окна морфа, наклон
        // сохраняется.
        let tokyoPullUp = ImmersiveMapCameraPosition(latitudeDegrees: tokyo.lat,
                                                     longitudeDegrees: tokyo.lon,
                                                     zoom: 7.6, bearing: -0.35, pitch: 1.28)
        shots.append(ImmersiveMapCameraTourShot(
            position: tokyoPullUp,
            options: CameraFlightOptions(duration: 3.0, routeStyle: .automatic, altitudeStyle: .direct),
            holdAfter: 0.2
        ))

        // 7. Медленный обратный морф: плоскость складывается в глобус под
        // тем же наклоном.
        let tokyoMorphOut = ImmersiveMapCameraPosition(latitudeDegrees: tokyo.lat,
                                                       longitudeDegrees: tokyo.lon,
                                                       zoom: 5.6, bearing: -0.55, pitch: 1.28)
        shots.append(ImmersiveMapCameraTourShot(
            position: tokyoMorphOut,
            options: CameraFlightOptions(duration: 5.0, routeStyle: .automatic, altitudeStyle: .direct),
            holdAfter: 0.4
        ))

        // 8. Дальний перелёт с отъездом на глобус и новым пикированием в Дубай.
        // Pitch интерполируется от наклонного отъезда: у апекса дуги его
        // прижмут констрейнты малого зума, на подлёте наклон вернётся.
        let dubaiStreet = ImmersiveMapCameraPosition(latitudeDegrees: dubai.lat,
                                                     longitudeDegrees: dubai.lon,
                                                     zoom: 16.4, bearing: -0.35, pitch: 1.0)
        shots.append(ImmersiveMapCameraTourShot(
            position: dubaiStreet,
            options: CameraFlightOptions(duration: 6.0, routeStyle: .greatCircle, altitudeStyle: .overviewFirst),
            holdAfter: 0.7
        ))

        // 9. Turntable вокруг Дубая.
        shots.append(contentsOf: orbit(base: dubaiStreet, segments: 3, perSegmentDuration: 2.3))

        // 10. Возврат на глобус в точку отправления: бесшовный шов лупа.
        shots.append(ImmersiveMapCameraTourShot(
            position: overview,
            options: CameraFlightOptions(duration: 4.6, routeStyle: .greatCircle, altitudeStyle: .overviewFirst),
            holdAfter: 0.8
        ))

        return shots
    }

    /// Разбивает полный оборот на равные сегменты (меньше 180 градусов каждый,
    /// чтобы перелёт крутил в нужную сторону), давая круговой облёт точки.
    private static func orbit(base: ImmersiveMapCameraPosition,
                              segments: Int,
                              perSegmentDuration: TimeInterval) -> [ImmersiveMapCameraTourShot] {
        let step = Float(2.0 * Double.pi / Double(segments))
        return (1...segments).map { index in
            let bearing = base.bearing + step * Float(index)
            return ImmersiveMapCameraTourShot(
                position: ImmersiveMapCameraPosition(latitudeDegrees: base.latitudeDegrees,
                                                     longitudeDegrees: base.longitudeDegrees,
                                                     zoom: base.zoom,
                                                     bearing: bearing,
                                                     pitch: base.pitch),
                options: CameraFlightOptions(duration: perSegmentDuration,
                                             routeStyle: .mercatorShortestPath,
                                             altitudeStyle: .direct),
                holdAfter: 0
            )
        }
    }
}
