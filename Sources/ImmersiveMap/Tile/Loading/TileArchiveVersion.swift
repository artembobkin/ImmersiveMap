// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import PMTiles

/// Which upload of the tile archive the map is reading, by the ETag the
/// host gives it, so an archive overwritten under the same URL is noticed.
///
/// A prepared tile on disk remembers the ETag it was parsed under
/// (`PreparedTileDiskCodec.Entry.sourceETag`, the archive's ETag and the
/// tile's id). The disk stage asks this type which ETag a tile must carry,
/// and an entry of another upload is passed over: the tile is downloaded
/// and parsed again, and the fresh parse replaces the entry.
///
/// The ETag is known without a request: the last one seen is kept on disk
/// and read at creation, so a warm start costs no network. One header
/// request per session then checks it, and every downloaded tile confirms
/// it. A changed ETag takes effect for the tiles loaded from then on. The
/// tiles already drawn stay for the session, so the frames right after a
/// new upload can mix the two until the next launch.
///
/// While the archive cannot be reached nothing is passed over: a tile of an
/// older upload is better than no tile. A host that sends no ETag, and an
/// archive read from disk, are not checked at all, as before.
///
/// `@unchecked Sendable`: the loads run in many tasks, and every path to
/// the mutable state goes through `lock`.
final class TileArchiveVersion: @unchecked Sendable {
    static let directoryName = "MapTileArchiveVersions"

    private let fileURL: URL
    private let lock = NSLock()
    /// The archive's ETag: the one remembered on disk until a response of
    /// this session says otherwise, nil when unknown or when the host
    /// sends none.
    private var archiveETag: String?
    /// The last request did not reach the archive.
    private var isUnreachable = false
    private var hasStartedCheck = false

    /// `sourceRevision` names the archive (`PreparedTileCacheIdentity.tileSourceRevision`).
    init(sourceRevision: UInt64, clearsRemembered: Bool = false, baseCachesDirectory: URL? = nil) {
        let cachesDirectory = baseCachesDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let directory = cachesDirectory.appendingPathComponent(Self.directoryName)
        fileURL = directory.appendingPathComponent(String(sourceRevision, radix: 16))
        if clearsRemembered {
            try? FileManager.default.removeItem(at: fileURL)
        }
        let remembered = try? String(contentsOf: fileURL, encoding: .utf8)
        archiveETag = remembered.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The source ETag a prepared tile on disk must carry to answer a load
    /// now, nil when any will do: the archive's ETag is unknown, the host
    /// sends none, or the archive cannot be reached.
    func expectedSourceETag(for tile: Tile) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard isUnreachable == false, let archiveETag,
              let tileID = PMTilesTileID.id(z: tile.z, x: tile.x, y: tile.y) else {
            return nil
        }
        return "\(archiveETag)/\(tileID)"
    }

    /// True once: the caller then asks the archive for its ETag and reports
    /// the answer, so a session checks even when every tile it needs is on
    /// disk already.
    func beginSessionCheck() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard hasStartedCheck == false else {
            return false
        }
        hasStartedCheck = true
        return true
    }

    /// The archive answered, with this ETag or with none.
    func observe(archiveETag observed: String?) {
        lock.lock()
        isUnreachable = false
        let changed = observed != archiveETag
        archiveETag = observed
        lock.unlock()
        guard changed else { return }
        let fileURL = self.fileURL
        // The write is small and rare, and losing it only costs the next
        // session one round of tiles checked against the older ETag.
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? Data((observed ?? "").utf8).write(to: fileURL, options: .atomic)
        }
    }

    /// A tile came from the archive under this source ETag, the archive's
    /// ETag and the tile's id as the downloader states them. A tile served
    /// with no source ETag says nothing about the archive.
    func observe(sourceETag: String?) {
        guard let sourceETag, let separator = sourceETag.lastIndex(of: "/") else {
            return
        }
        let archivePart = String(sourceETag[..<separator])
        observe(archiveETag: archivePart == "-" ? nil : archivePart)
    }

    /// A request did not reach the archive.
    func observeUnreachable() {
        lock.lock()
        isUnreachable = true
        lock.unlock()
    }
}
