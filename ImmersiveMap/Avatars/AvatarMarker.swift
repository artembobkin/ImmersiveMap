// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import CoreGraphics
import simd
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct GeoCoordinate: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct AvatarBatteryBadge: Equatable, Hashable, Sendable {
    public let levelPct: Int
    public let isPlaceholder: Bool

    public init(levelPct: Int) {
        self.levelPct = max(0, min(100, levelPct))
        self.isPlaceholder = false
    }

    private init(levelPct: Int, isPlaceholder: Bool) {
        self.levelPct = max(0, min(100, levelPct))
        self.isPlaceholder = isPlaceholder
    }

    public static var unavailable: AvatarBatteryBadge {
        AvatarBatteryBadge(levelPct: 0, isPlaceholder: true)
    }
}

public struct AvatarSpeedBadge: Equatable, Hashable, Sendable {
    public let kilometersPerHour: Int
    public let isPlaceholder: Bool

    public init(kilometersPerHour: Int) {
        self.kilometersPerHour = max(0, min(999, kilometersPerHour))
        self.isPlaceholder = false
    }

    private init(kilometersPerHour: Int, isPlaceholder: Bool) {
        self.kilometersPerHour = max(0, min(999, kilometersPerHour))
        self.isPlaceholder = isPlaceholder
    }

    public static var unavailable: AvatarSpeedBadge {
        AvatarSpeedBadge(kilometersPerHour: 0, isPlaceholder: true)
    }
}

public enum AvatarClusterPolicy: Equatable, Hashable, Sendable {
    case none
    case event
}

/// Bubble-счётчик у маркера: показывает число объединённых аватаров.
/// Ставится автоматически на merged-маркеры (`ImmersiveMapAvatarsController.merge`),
/// но может задаваться и вручную. Значения выше 999 рисуются как «999+».
public struct AvatarCountBadge: Equatable, Hashable, Sendable {
    public let count: Int

    public init(count: Int) {
        self.count = max(1, count)
    }
}

public struct AvatarMarker: Sendable {
    public let id: UInt64
    public var coordinate: GeoCoordinate
    public var image: CGImage
    public var imageSource: AvatarMarkerImageSource
    public var batteryBadge: AvatarBatteryBadge?
    public var speedBadge: AvatarSpeedBadge?
    public var countBadge: AvatarCountBadge?
    public var borderColor: SIMD4<Float>?
    public var screenSizeScale: Float
    public var isSelected: Bool
    public var drawPriority: Int
    public var clusterPolicy: AvatarClusterPolicy

    public init(id: UInt64,
                coordinate: GeoCoordinate,
                image: CGImage,
                batteryBadge: AvatarBatteryBadge? = nil,
                speedBadge: AvatarSpeedBadge? = nil,
                countBadge: AvatarCountBadge? = nil,
                borderColor: SIMD4<Float>? = nil,
                screenSizeScale: Float = 1.0,
                isSelected: Bool = false,
                drawPriority: Int = 0,
                clusterPolicy: AvatarClusterPolicy = .none) {
        self.id = id
        self.coordinate = coordinate
        self.image = image
        self.imageSource = .cgImage(image)
        self.batteryBadge = batteryBadge
        self.speedBadge = speedBadge
        self.countBadge = countBadge
        self.borderColor = borderColor
        self.screenSizeScale = screenSizeScale
        self.isSelected = isSelected
        self.drawPriority = drawPriority
        self.clusterPolicy = clusterPolicy
    }

    public init(id: UInt64,
                coordinate: GeoCoordinate,
                image: AvatarMarkerImageSource,
                batteryBadge: AvatarBatteryBadge? = nil,
                speedBadge: AvatarSpeedBadge? = nil,
                countBadge: AvatarCountBadge? = nil,
                borderColor: SIMD4<Float>? = nil,
                screenSizeScale: Float = 1.0,
                isSelected: Bool = false,
                drawPriority: Int = 0,
                clusterPolicy: AvatarClusterPolicy = .none) {
        self.id = id
        self.coordinate = coordinate
        self.image = image.initialImage
        self.imageSource = image
        self.batteryBadge = batteryBadge
        self.speedBadge = speedBadge
        self.countBadge = countBadge
        self.borderColor = borderColor
        self.screenSizeScale = screenSizeScale
        self.isSelected = isSelected
        self.drawPriority = drawPriority
        self.clusterPolicy = clusterPolicy
    }

    /// Быстрая сборка аватара с картинкой из сети.
    ///
    /// Координаты задаются как широта/долгота, картинка грузится по `imageURL`
    /// (до загрузки показывается `placeholder` либо встроенная заглушка).
    /// `batteryPercent`/`speedKilometersPerHour` опциональны: `nil` означает, что
    /// соответствующий бейдж не рисуется.
    public init(id: UInt64,
                latitude: Double,
                longitude: Double,
                imageURL: URL,
                placeholder: CGImage? = nil,
                batteryPercent: Int? = nil,
                speedKilometersPerHour: Int? = nil,
                borderColor: SIMD4<Float>? = nil,
                screenSizeScale: Float = 1.0,
                isSelected: Bool = false,
                drawPriority: Int = 0,
                clusterPolicy: AvatarClusterPolicy = .none) {
        self.init(id: id,
                  coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                  image: .remote(imageURL, placeholder: placeholder),
                  batteryBadge: batteryPercent.map { AvatarBatteryBadge(levelPct: $0) },
                  speedBadge: speedKilometersPerHour.map { AvatarSpeedBadge(kilometersPerHour: $0) },
                  borderColor: borderColor,
                  screenSizeScale: screenSizeScale,
                  isSelected: isSelected,
                  drawPriority: drawPriority,
                  clusterPolicy: clusterPolicy)
    }

    /// Быстрая сборка аватара с готовой (локальной) картинкой.
    ///
    /// Симметрична сетевому инициализатору, но принимает уже нарисованный
    /// `CGImage` - например результат `AvatarMarkerImageFactory.number(_:)`.
    /// `batteryPercent`/`speedKilometersPerHour` опциональны: `nil` означает, что
    /// соответствующий бейдж не рисуется.
    public init(id: UInt64,
                latitude: Double,
                longitude: Double,
                image: CGImage,
                batteryPercent: Int? = nil,
                speedKilometersPerHour: Int? = nil,
                borderColor: SIMD4<Float>? = nil,
                screenSizeScale: Float = 1.0,
                isSelected: Bool = false,
                drawPriority: Int = 0,
                clusterPolicy: AvatarClusterPolicy = .none) {
        self.init(id: id,
                  coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                  image: image,
                  batteryBadge: batteryPercent.map { AvatarBatteryBadge(levelPct: $0) },
                  speedBadge: speedKilometersPerHour.map { AvatarSpeedBadge(kilometersPerHour: $0) },
                  borderColor: borderColor,
                  screenSizeScale: screenSizeScale,
                  isSelected: isSelected,
                  drawPriority: drawPriority,
                  clusterPolicy: clusterPolicy)
    }

#if canImport(UIKit)
    public init(id: UInt64,
                coordinate: GeoCoordinate,
                image: UIImage,
                batteryBadge: AvatarBatteryBadge? = nil,
                speedBadge: AvatarSpeedBadge? = nil,
                borderColor: SIMD4<Float>? = nil,
                screenSizeScale: Float = 1.0,
                isSelected: Bool = false,
                drawPriority: Int = 0,
                clusterPolicy: AvatarClusterPolicy = .none) {
        guard let cgImage = image.cgImage else {
            preconditionFailure("UIImage must have CGImage backing.")
        }
        self.init(id: id,
                  coordinate: coordinate,
                  image: cgImage,
                  batteryBadge: batteryBadge,
                  speedBadge: speedBadge,
                  borderColor: borderColor,
                  screenSizeScale: screenSizeScale,
                  isSelected: isSelected,
                  drawPriority: drawPriority,
                  clusterPolicy: clusterPolicy)
    }
#elseif canImport(AppKit)
    public init(id: UInt64,
                coordinate: GeoCoordinate,
                image: NSImage,
                batteryBadge: AvatarBatteryBadge? = nil,
                speedBadge: AvatarSpeedBadge? = nil,
                borderColor: SIMD4<Float>? = nil,
                screenSizeScale: Float = 1.0,
                isSelected: Bool = false,
                drawPriority: Int = 0,
                clusterPolicy: AvatarClusterPolicy = .none) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            preconditionFailure("NSImage must be convertible to CGImage.")
        }
        self.init(id: id,
                  coordinate: coordinate,
                  image: cgImage,
                  batteryBadge: batteryBadge,
                  speedBadge: speedBadge,
                  borderColor: borderColor,
                  screenSizeScale: screenSizeScale,
                  isSelected: isSelected,
                  drawPriority: drawPriority,
                  clusterPolicy: clusterPolicy)
    }
#endif
}
