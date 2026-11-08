// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// How deep each tile archive goes: the deepest zoom its header names
/// (`PMTilesHeader.maxZoom`), by the archive's source revision
/// (`PreparedTileCacheIdentity.tileSourceRevision`). The map asks an
/// archive for no tile deeper, and stretches its deepest ones past it
/// (`TileSettings.CoverageSettings.resolvedMaximumZoomLevel`).
///
/// The depth is known without a request: the last one read is kept on
/// disk, so a warm start plans its first frame by it. The load pipeline
/// reads the header once a session and reports the depth here, and a
/// depth that differs from the one kept is posted as `didChange`, on the
/// main queue, for the map to plan by it from then on. Until an archive's
/// depth was ever read, the map plans by its provisional depth.
///
/// `@unchecked Sendable`: the pipeline reports from its tasks, and every
/// path to the mutable state goes through `lock`.
final class TileArchiveDepths: @unchecked Sendable {
    static let directoryName = "MapTileArchiveDepths"
    /// Posted on the main queue when an archive's depth turns out other than
    /// the one kept, with the archive's source revision as the object.
    static let didChange = Notification.Name("ImmersiveMapTileArchiveDepthDidChange")

    static let shared = TileArchiveDepths()

    private let directory: URL
    private let lock = NSLock()
    /// The depths read this process, and the ones read back from disk.
    private var depths: [UInt64: Int] = [:]

    init(baseCachesDirectory: URL? = nil) {
        let cachesDirectory = baseCachesDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        directory = cachesDirectory.appendingPathComponent(Self.directoryName)
    }

    /// The deepest zoom of the archive, nil when it was never read.
    func maximumZoom(sourceRevision: UInt64) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if let depth = depths[sourceRevision] {
            return depth
        }
        guard let text = try? String(contentsOf: fileURL(sourceRevision), encoding: .utf8),
              let depth = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        depths[sourceRevision] = depth
        return depth
    }

    /// The depth the archive's header names, read this session. A depth
    /// other than the one kept is written down and posted.
    func observe(maximumZoom: Int, sourceRevision: UInt64) {
        let previous = self.maximumZoom(sourceRevision: sourceRevision)
        guard previous != maximumZoom else {
            return
        }
        lock.lock()
        depths[sourceRevision] = maximumZoom
        lock.unlock()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? String(maximumZoom).write(to: fileURL(sourceRevision), atomically: true, encoding: .utf8)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: sourceRevision)
        }
    }

    private func fileURL(_ sourceRevision: UInt64) -> URL {
        directory.appendingPathComponent(String(sourceRevision, radix: 16))
    }
}
