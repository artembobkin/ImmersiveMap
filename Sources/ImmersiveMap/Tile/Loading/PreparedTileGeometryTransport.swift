// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Decides how a prepared tile's geometry blob is stored next to its
/// metadata. The Metal-aware implementation lives on the render side (the
/// `Tile` domain stays free of Metal); the inline implementation below is
/// the universal fallback.
///
/// File-transport writes are split in two so the shared serial IO queue
/// stays a queue of cheap file operations: `stageBlobFile` does the actual
/// encoding (LZFSE chunk compression is CPU work over a multi-megabyte
/// arena) on the calling task, and `commitStagedBlobFile` is just the atomic
/// swap, run on the IO queue where it serializes with reads and removals.
protocol PreparedTileGeometryTransporting: Sendable {
    /// Mixed into the cache directory namespace so transports never read
    /// each other's entries: an MTLIO container is unreadable on a device
    /// without Metal 3, and an inline entry would be dead weight on one
    /// with it.
    var cacheNamespaceMarker: String { get }
    /// How entries written through this transport store their geometry blob;
    /// `.file` also names the format `stageBlobFile` writes, which the codec
    /// records per entry so readers open the container correctly regardless
    /// of the current compression setting.
    var blobTransport: PreparedTileGeometryBlobTransport { get }
    /// Writes the blob into a unique temporary file next to `url` and
    /// returns the staged URL. Heavy (may compress); runs on the calling
    /// task. Called only when `blobTransport` is `.file`.
    func stageBlobFile(_ blob: Data, near url: URL) throws -> URL
    /// Atomically swaps a staged file into place, consuming it (the staged
    /// file is removed on failure). Cheap; runs on the shared IO queue.
    /// Called only when `blobTransport` is `.file`.
    func commitStagedBlobFile(at stagedURL: URL, to url: URL) throws
}

extension PreparedTileGeometryTransporting {
    /// A unique sibling path for a staged blob. Staged files live inside the
    /// cache directory, so one orphaned by a crash is indexed and aged out
    /// like any entry.
    func makeStagingURL(near url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).tmp-\(UUID().uuidString)")
    }

    /// The atomic swap shared by every file transport: `replaceItemAt` needs
    /// an existing original, so the first save of a tile moves the staged
    /// file instead. Readers that already opened the previous container keep
    /// its inode; the next open sees the new one.
    func replaceFile(at url: URL, withStagedFileAt stagedURL: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: stagedURL)
            } else {
                try FileManager.default.moveItem(at: stagedURL, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }
    }
}

/// Inline-only transport: the blob rides inside the metadata envelope and is
/// materialized with one CPU copy. Used where MTLIO cannot load (Intel Macs,
/// the simulator) and in tests.
struct InlinePreparedTileGeometryTransport: PreparedTileGeometryTransporting {
    let cacheNamespaceMarker = "binl"
    let blobTransport = PreparedTileGeometryBlobTransport.inline

    func stageBlobFile(_ blob: Data, near url: URL) throws -> URL {
        assertionFailure("The inline transport never writes blob files")
        throw PreparedTileDiskCodecError.invalidField("InlinePreparedTileGeometryTransport.stageBlobFile")
    }

    func commitStagedBlobFile(at stagedURL: URL, to url: URL) throws {
        assertionFailure("The inline transport never writes blob files")
        throw PreparedTileDiskCodecError.invalidField("InlinePreparedTileGeometryTransport.commitStagedBlobFile")
    }
}
