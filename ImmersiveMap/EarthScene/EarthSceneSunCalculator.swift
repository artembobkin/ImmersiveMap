// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct EarthSceneSubsolarPoint: Equatable {
    let latitudeDegrees: Double
    let longitudeDegrees: Double
}

enum EarthSceneSunCalculator {
    static func subsolarPoint(at date: Date) -> EarthSceneSubsolarPoint {
        let fractionalYear = fractionalYearRadians(at: date)
        let equationOfTimeMinutes = equationOfTimeMinutes(fractionalYear)
        let declinationRadians = solarDeclinationRadians(fractionalYear)
        let longitudeDegrees = normalizedLongitudeDegrees((720.0 - utcMinutes(at: date) - equationOfTimeMinutes) / 4.0)

        return EarthSceneSubsolarPoint(
            latitudeDegrees: degrees(fromRadians: declinationRadians),
            longitudeDegrees: longitudeDegrees
        )
    }

    static func earthFixedSunDirection(at date: Date) -> SIMD3<Float> {
        let subsolarPoint = subsolarPoint(at: date)
        return earthFixedDirection(latitudeDegrees: subsolarPoint.latitudeDegrees,
                                   longitudeDegrees: subsolarPoint.longitudeDegrees)
    }

    static func earthFixedDirection(latitudeDegrees: Double, longitudeDegrees: Double) -> SIMD3<Float> {
        let latitudeRadians = radians(fromDegrees: latitudeDegrees)
        let longitudeRadians = radians(fromDegrees: longitudeDegrees)
        let latitudeCosine = cos(latitudeRadians)

        return SIMD3<Float>(
            Float(latitudeCosine * sin(longitudeRadians)),
            Float(sin(latitudeRadians)),
            Float(latitudeCosine * cos(longitudeRadians))
        )
    }

    private static func fractionalYearRadians(at date: Date) -> Double {
        let dayOfYear = Double(utcCalendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        return (2.0 * .pi / 365.0) * (dayOfYear - 1.0 + (utcHours(at: date) - 12.0) / 24.0)
    }

    private static func equationOfTimeMinutes(_ fractionalYear: Double) -> Double {
        229.18 * (
            0.000075
            + 0.001868 * cos(fractionalYear)
            - 0.032077 * sin(fractionalYear)
            - 0.014615 * cos(2.0 * fractionalYear)
            - 0.040849 * sin(2.0 * fractionalYear)
        )
    }

    private static func solarDeclinationRadians(_ fractionalYear: Double) -> Double {
        0.006918
            - 0.399912 * cos(fractionalYear)
            + 0.070257 * sin(fractionalYear)
            - 0.006758 * cos(2.0 * fractionalYear)
            + 0.000907 * sin(2.0 * fractionalYear)
            - 0.002697 * cos(3.0 * fractionalYear)
            + 0.00148 * sin(3.0 * fractionalYear)
    }

    private static func utcHours(at date: Date) -> Double {
        let components = utcCalendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        return Double(components.hour ?? 0)
            + Double(components.minute ?? 0) / 60.0
            + Double(components.second ?? 0) / 3_600.0
            + Double(components.nanosecond ?? 0) / 3_600_000_000_000.0
    }

    private static func utcMinutes(at date: Date) -> Double {
        utcHours(at: date) * 60.0
    }

    private static func normalizedLongitudeDegrees(_ longitudeDegrees: Double) -> Double {
        var longitude = longitudeDegrees.truncatingRemainder(dividingBy: 360.0)
        if longitude > 180.0 {
            longitude -= 360.0
        } else if longitude < -180.0 {
            longitude += 360.0
        }
        return longitude
    }

    private static func radians(fromDegrees degrees: Double) -> Double {
        degrees * .pi / 180.0
    }

    private static func degrees(fromRadians radians: Double) -> Double {
        radians * 180.0 / .pi
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}
