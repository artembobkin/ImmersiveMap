// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import CoreGraphics
import simd
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum PinClusterPolicy: Equatable, Hashable, Sendable {
    case none
    case event
}

/// Bubble counter on a pin: shows the number of merged pins.
/// Set automatically on merged pins (`ImmersiveMapPinsController.merge`),
/// but can also be assigned manually. Values above 999 render as "999+".
public struct PinCountBadge: Equatable, Hashable, Sendable {
    public let count: Int

    public init(count: Int) {
        self.count = max(1, count)
    }
}

public struct ImmersiveMapPin: Sendable {
    public let id: UInt64
    public var coordinate: GeoCoordinate
    public var image: CGImage
    public var imageSource: PinImageSource
    public var countBadge: PinCountBadge?
    public var borderColor: SIMD4<Float>?
    public var screenSizeScale: Float
    public var isSelected: Bool
    public var drawPriority: Int
    public var clusterPolicy: PinClusterPolicy

    public init(id: UInt64,
                coordinate: GeoCoordinate,
                image: CGImage,
                countBadge: PinCountBadge? = nil,
                borderColor: SIMD4<Float>? = nil,
                screenSizeScale: Float = 1.0,
                isSelected: Bool = false,
                drawPriority: Int = 0,
                clusterPolicy: PinClusterPolicy = .none) {
        self.id = id
        self.coordinate = coordinate
        self.image = image
        self.imageSource = .cgImage(image)
        self.countBadge = countBadge
        self.borderColor = borderColor
        self.screenSizeScale = screenSizeScale
        self.isSelected = isSelected
        self.drawPriority = drawPriority
        self.clusterPolicy = clusterPolicy
    }

    public init(id: UInt64,
                coordinate: GeoCoordinate,
                image: PinImageSource,
                countBadge: PinCountBadge? = nil,
                borderColor: SIMD4<Float>? = nil,
                screenSizeScale: Float = 1.0,
                isSelected: Bool = false,
                drawPriority: Int = 0,
                clusterPolicy: PinClusterPolicy = .none) {
        self.id = id
        self.coordinate = coordinate
        self.image = image.initialImage
        self.imageSource = image
        self.countBadge = countBadge
        self.borderColor = borderColor
        self.screenSizeScale = screenSizeScale
        self.isSelected = isSelected
        self.drawPriority = drawPriority
        self.clusterPolicy = clusterPolicy
    }

    /// Convenience pin builder with a network-loaded image.
    ///
    /// Coordinates are given as latitude/longitude, the image is loaded from `imageURL`
    /// (until it loads, `placeholder` or the built-in stub is shown).
    public init(id: UInt64,
                latitude: Double,
                longitude: Double,
                imageURL: URL,
                placeholder: CGImage? = nil,
                borderColor: SIMD4<Float>? = nil,
                screenSizeScale: Float = 1.0,
                isSelected: Bool = false,
                drawPriority: Int = 0,
                clusterPolicy: PinClusterPolicy = .none) {
        self.init(id: id,
                  coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                  image: .remote(imageURL, placeholder: placeholder),
                  borderColor: borderColor,
                  screenSizeScale: screenSizeScale,
                  isSelected: isSelected,
                  drawPriority: drawPriority,
                  clusterPolicy: clusterPolicy)
    }

    /// Convenience pin builder with a ready (local) image.
    ///
    /// Symmetric to the network initializer, but takes an already rendered
    /// `CGImage` - e.g. the result of `PinImageFactory.number(_:)`.
    public init(id: UInt64,
                latitude: Double,
                longitude: Double,
                image: CGImage,
                borderColor: SIMD4<Float>? = nil,
                screenSizeScale: Float = 1.0,
                isSelected: Bool = false,
                drawPriority: Int = 0,
                clusterPolicy: PinClusterPolicy = .none) {
        self.init(id: id,
                  coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                  image: image,
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
                borderColor: SIMD4<Float>? = nil,
                screenSizeScale: Float = 1.0,
                isSelected: Bool = false,
                drawPriority: Int = 0,
                clusterPolicy: PinClusterPolicy = .none) {
        guard let cgImage = image.cgImage else {
            preconditionFailure("UIImage must have CGImage backing.")
        }
        self.init(id: id,
                  coordinate: coordinate,
                  image: cgImage,
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
                borderColor: SIMD4<Float>? = nil,
                screenSizeScale: Float = 1.0,
                isSelected: Bool = false,
                drawPriority: Int = 0,
                clusterPolicy: PinClusterPolicy = .none) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            preconditionFailure("NSImage must be convertible to CGImage.")
        }
        self.init(id: id,
                  coordinate: coordinate,
                  image: cgImage,
                  borderColor: borderColor,
                  screenSizeScale: screenSizeScale,
                  isSelected: isSelected,
                  drawPriority: drawPriority,
                  clusterPolicy: clusterPolicy)
    }
#endif
}
