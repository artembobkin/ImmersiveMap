// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// What can be wrong with the bytes of an archive. Every case names the
/// place it was found so a wrong URL (an HTML page, an old v2 archive, a
/// brotli build) is diagnosable from the message alone.
package enum PMTilesFormatError: Error, Equatable, Sendable {
    case badMagic
    case unsupportedVersion(UInt8)
    case unsupportedCompression(UInt8)
    case unsupportedTileType(UInt8)
    case truncated
    case malformedDirectory(String)
    case corruptCompressedData
    case decompressedDataTooLarge
}
