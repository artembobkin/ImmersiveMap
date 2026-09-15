// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  AvatarMarkerSDFResource.swift
//  ImmersiveMap
//

import Foundation
import Metal
import MetalKit

struct AvatarMarkerSDFParams {
    var distanceRangeTexels: Float
}

struct AvatarMarkerSDFShapeMetrics {
    var pointerHeightRatio: Float
}

private struct AvatarMarkerSDFMetadata: Decodable {
    let schemaVersion: Int
    let distanceRangeTexels: Float
    let imageWidth: Int
    let imageHeight: Int
    let pointerHeightRatio: Float
}

enum AvatarMarkerSDFResourceError: Error {
    case missingTextureResource(String)
    case missingMetadataResource(String)
    case failedToLoadTexture(URL, Error)
    case failedToDecodeMetadata(URL, Error)
    case incompatibleMetadataSchema(Int)
    case metadataTextureSizeMismatch(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
}

final class AvatarMarkerSDFResource {
    static let baseName = "avatar_marker_sdf"
    static let supportedSchemaVersion = 1

    let texture: MTLTexture
    let params: AvatarMarkerSDFParams
    let shapeMetrics: AvatarMarkerSDFShapeMetrics

    init(device: MTLDevice,
         bundle: Bundle = .module) throws {
        let textureURL = try Self.textureURL(in: bundle)
        let metadataURL = try Self.metadataURL(in: bundle)

        let textureLoader = MTKTextureLoader(device: device)
        do {
            self.texture = try textureLoader.newTexture(URL: textureURL,
                                                        options: [
                                                            .SRGB: false
                                                        ])
        } catch {
            throw AvatarMarkerSDFResourceError.failedToLoadTexture(textureURL, error)
        }

        let metadata: AvatarMarkerSDFMetadata
        do {
            let data = try Data(contentsOf: metadataURL)
            metadata = try JSONDecoder().decode(AvatarMarkerSDFMetadata.self, from: data)
        } catch {
            throw AvatarMarkerSDFResourceError.failedToDecodeMetadata(metadataURL, error)
        }

        guard metadata.schemaVersion == Self.supportedSchemaVersion else {
            throw AvatarMarkerSDFResourceError.incompatibleMetadataSchema(metadata.schemaVersion)
        }
        guard metadata.imageWidth == texture.width,
              metadata.imageHeight == texture.height else {
            throw AvatarMarkerSDFResourceError.metadataTextureSizeMismatch(expectedWidth: metadata.imageWidth,
                                                                          expectedHeight: metadata.imageHeight,
                                                                          actualWidth: texture.width,
                                                                          actualHeight: texture.height)
        }

        self.params = AvatarMarkerSDFParams(distanceRangeTexels: metadata.distanceRangeTexels)
        self.shapeMetrics = AvatarMarkerSDFShapeMetrics(pointerHeightRatio: metadata.pointerHeightRatio)
    }

    private static func textureURL(in bundle: Bundle) throws -> URL {
        guard let url = bundle.url(forResource: baseName, withExtension: "png") else {
            throw AvatarMarkerSDFResourceError.missingTextureResource("\(baseName).png")
        }
        return url
    }

    private static func metadataURL(in bundle: Bundle) throws -> URL {
        guard let url = bundle.url(forResource: baseName, withExtension: "json") else {
            throw AvatarMarkerSDFResourceError.missingMetadataResource("\(baseName).json")
        }
        return url
    }
}
