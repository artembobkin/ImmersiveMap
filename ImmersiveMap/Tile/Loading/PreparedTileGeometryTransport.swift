// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Decides how a prepared tile's geometry blob is stored next to its
/// metadata. The Metal-aware implementation lives on the render side (the
/// `Tile` domain stays free of Metal); the inline implementation below is
/// the universal fallback.
protocol PreparedTileGeometryTransporting: Sendable {
    /// Mixed into the cache directory namespace so transports never read
    /// each other's entries: an MTLIO container is unreadable on a device
    /// without Metal 3, and an inline entry would be dead weight on one
    /// with it.
    var cacheNamespaceMarker: String { get }
    /// true: `writeBlobFile` stores the blob as an MTLIO compression
    /// container next to the metadata and hits DMA-load it. false: the blob
    /// travels inline inside the metadata envelope.
    var writesBlobFiles: Bool { get }
    /// Called only when `writesBlobFiles` is true. Must replace the file at
    /// `url` atomically (write to a sibling temp path, then rename).
    func writeBlobFile(_ blob: Data, to url: URL) throws
}

/// Inline-only transport: the blob rides inside the metadata envelope and is
/// materialized with one CPU copy. Used where MTLIO cannot load (Intel Macs,
/// the simulator) and in tests.
struct InlinePreparedTileGeometryTransport: PreparedTileGeometryTransporting {
    let cacheNamespaceMarker = "binl"
    let writesBlobFiles = false

    func writeBlobFile(_ blob: Data, to url: URL) throws {
        assertionFailure("The inline transport never writes blob files")
        throw PreparedTileDiskCodecError.invalidField("InlinePreparedTileGeometryTransport.writeBlobFile")
    }
}
