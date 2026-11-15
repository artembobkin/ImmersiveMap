// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// The sources an app registered with a layers controller, and the ones
/// that are read. A source costs nothing until its shapes are needed: to
/// build the mesh of a layer that draws it, when the disk holds none
/// (`LayerMeshDiskCache`), and to test a tap against, when the app listens
/// to taps on its layers (`shapesWanted`). It is then read off the main
/// thread, and its shapes are let go as soon as nothing needs them. The
/// shapes held are bounded by the input limit: over it, the source drawn
/// last in the layers' order is refused
/// (`ImmersiveMapLayerSourceError.limitExceeded`).
///
/// One library serves every map that draws the controller's layers, the
/// map on screen and an export of it: each is a client that says what it
/// draws every frame and is told when a source it waits for has been read.
///
/// Thread-safe (`@unchecked Sendable`): the state is serialized by `lock`.
/// The app registers from any thread, the frames read on the main thread,
/// the reads finish on theirs.
final class LayerSourceLibrary: @unchecked Sendable {
    /// A source as a frame sees it.
    struct State {
        /// Changes when the source is registered with other data.
        let revision: UInt64
        /// The shapes, nil while they are not read.
        let content: LayerSourceContent?
        /// Whether the shapes are on their way.
        let isLoading: Bool
        /// Whether the source cannot be drawn: unreadable, or refused for
        /// the limit.
        let isFailed: Bool
        /// What the source's data is told apart by: what a mesh kept on
        /// disk goes by.
        let identity: LayerSourceIdentity
    }

    private struct Entry {
        var data: LayerSourceData
        var revision: UInt64
        var content: LayerSourceContent?
        var isLoading = false
        var failure: ImmersiveMapLayerSourceError?
    }

    private struct Client {
        var onChange: @Sendable () -> Void
        /// The sources whose shapes the client needed last, in the order
        /// of its layers.
        var needed: [String] = []
    }

    let limitBytes: Int
    /// Where the meshes of the layers that draw a file are kept.
    let meshCache: LayerMeshDiskCache

    private let lock = NSLock()
    private var wantsShapes = false
    private var entries: [String: Entry] = [:]
    private var nextRevision: UInt64 = 1
    private var clients: [ObjectIdentifier: Client] = [:]
    private var failureHandler: (@Sendable (String, ImmersiveMapLayerSourceError) -> Void)?

    init(limitBytes: Int, meshCache: LayerMeshDiskCache = LayerMeshDiskCache(limitBytes: 0)) {
        self.limitBytes = max(limitBytes, 0)
        self.meshCache = meshCache
    }

    /// Whether the shapes of every drawn source are kept at hand, for a
    /// tap to be tested against: on while the app listens to taps on its
    /// layers or holds a selection. Off, a drawn layer needs its mesh
    /// alone.
    var shapesWanted: Bool {
        get { lock.withLock { wantsShapes } }
        set {
            lock.lock()
            let changed = wantsShapes != newValue
            wantsShapes = newValue
            let handlers = changed ? changeHandlers() : []
            lock.unlock()
            handlers.forEach { $0() }
        }
    }

    // MARK: - The app's side

    /// Registers `data` under `name`, in the place of what was there.
    /// Nothing changes when it is the data already registered.
    func register(_ name: String, _ data: LayerSourceData) {
        lock.lock()
        if entries[name]?.data == data {
            lock.unlock()
            return
        }
        entries[name] = Entry(data: data, revision: nextRevision)
        nextRevision += 1
        retryRefused()
        let handlers = changeHandlers()
        lock.unlock()
        handlers.forEach { $0() }
    }

    func unregister(_ name: String) {
        lock.lock()
        guard entries.removeValue(forKey: name) != nil else {
            lock.unlock()
            return
        }
        retryRefused()
        let handlers = changeHandlers()
        lock.unlock()
        handlers.forEach { $0() }
    }

    var names: [String] {
        lock.withLock { entries.keys.sorted() }
    }

    func failure(of name: String) -> ImmersiveMapLayerSourceError? {
        lock.withLock { entries[name]?.failure }
    }

    /// Whether the shapes of `name` are read and held.
    func isLoaded(_ name: String) -> Bool {
        lock.withLock { entries[name]?.content != nil }
    }

    /// The memory of the shapes that are read, what the limit bounds.
    var loadedBytes: Int {
        lock.withLock { totalBytes() }
    }

    func setFailureHandler(_ handler: (@Sendable (String, ImmersiveMapLayerSourceError) -> Void)?) {
        lock.withLock { failureHandler = handler }
    }

    // MARK: - The frames' side

    /// Adds a map that draws from the library. `onChange` is called, from
    /// any thread, when a source was registered, removed or read.
    func addClient(_ client: AnyObject, onChange: @escaping @Sendable () -> Void) {
        lock.withLock { clients[ObjectIdentifier(client)] = Client(onChange: onChange) }
    }

    func removeClient(_ client: AnyObject) {
        lock.withLock { _ = clients.removeValue(forKey: ObjectIdentifier(client)) }
    }

    /// The states of `sources`, nil for a name nothing is registered under.
    /// `drawn` are the sources the client's frame draws, in the order of
    /// its layers, and `building` those among them a mesh is to be built
    /// from. The shapes of a source are needed while it is in `building`,
    /// and while it is drawn when `shapesWanted`: a needed source that is
    /// not read starts to be, and the shapes no client needs are let go.
    func states(of sources: Set<String>,
                drawn: [String],
                building: Set<String> = [],
                client: AnyObject) -> [String: State] {
        var toLoad: [(name: String, revision: UInt64, data: LayerSourceData)] = []
        lock.lock()
        let needed = wantsShapes ? drawn : drawn.filter(building.contains)
        clients[ObjectIdentifier(client)]?.needed = needed
        let allNeeded = neededByAnyClient()
        // What nobody needs any more is let go, and a source refused for
        // the limit may fit in the room that makes.
        var released = false
        for name in entries.keys where entries[name]?.content != nil && allNeeded.contains(name) == false {
            entries[name]?.content = nil
            released = true
        }
        if released {
            retryRefused()
        }
        for name in needed {
            guard var entry = entries[name], entry.content == nil, entry.isLoading == false,
                  entry.failure == nil else { continue }
            entry.isLoading = true
            entries[name] = entry
            toLoad.append((name, entry.revision, entry.data))
        }
        var result: [String: State] = [:]
        for name in sources {
            guard let entry = entries[name] else { continue }
            result[name] = State(revision: entry.revision,
                                 content: entry.content,
                                 isLoading: entry.isLoading,
                                 isFailed: entry.failure != nil,
                                 identity: entry.data.identity)
        }
        lock.unlock()

        for load in toLoad {
            self.load(load.name, revision: load.revision, data: load.data)
        }
        return result
    }

    /// Lets go of the shapes of every source no map needs now. They are
    /// read again when they are needed.
    func releaseUnneeded() {
        lock.withLock {
            let allNeeded = neededByAnyClient()
            for name in entries.keys where allNeeded.contains(name) == false {
                entries[name]?.content = nil
            }
        }
    }

    // MARK: - Reading

    private func load(_ name: String, revision: UInt64, data: LayerSourceData) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Result { try LayerSourceContent.load(data) }
            self?.finishLoad(name, revision: revision, outcome: outcome)
        }
    }

    private func finishLoad(_ name: String, revision: UInt64, outcome: Result<LayerSourceContent, Error>) {
        var failures: [(String, ImmersiveMapLayerSourceError)] = []
        lock.lock()
        // The source was registered anew or removed while this was read:
        // what was read is of no use.
        guard var entry = entries[name], entry.revision == revision else {
            lock.unlock()
            return
        }
        entry.isLoading = false
        switch outcome {
        case .success(let content):
            entry.content = content
            entries[name] = entry
            failures = enforceLimit()
        case .failure(let error):
            let failure = error as? ImmersiveMapLayerSourceError ?? .unreadableFile(error.localizedDescription)
            entry.failure = failure
            entries[name] = entry
            failures = [(name, failure)]
        }
        let handlers = changeHandlers()
        let failureHandler = failureHandler
        lock.unlock()

        handlers.forEach { $0() }
        if let failureHandler, failures.isEmpty == false {
            DispatchQueue.main.async {
                failures.forEach { failureHandler($0.0, $0.1) }
            }
        }
    }

    /// Brings the shapes held under the limit, with `lock` held: those of
    /// the sources no map needs go first, then the needed sources from the
    /// last of the layers' order are refused. Returns the refused.
    private func enforceLimit() -> [(String, ImmersiveMapLayerSourceError)] {
        var total = totalBytes()
        guard total > limitBytes else { return [] }

        let neededOrder = clients.values.flatMap(\.needed)
        let allNeeded = Set(neededOrder)
        for name in entries.keys.sorted() where total > limitBytes && allNeeded.contains(name) == false {
            total -= entries[name]?.content?.byteSize ?? 0
            entries[name]?.content = nil
        }

        var refused: [(String, ImmersiveMapLayerSourceError)] = []
        for name in neededOrder.reversed() where total > limitBytes {
            guard let size = entries[name]?.content?.byteSize else { continue }
            let failure = ImmersiveMapLayerSourceError.limitExceeded(bytes: size, limit: limitBytes)
            total -= size
            entries[name]?.content = nil
            entries[name]?.failure = failure
            refused.append((name, failure))
        }
        return refused
    }

    /// The sources refused for the limit may fit now that the set of
    /// sources changed, with `lock` held: the next frame that draws one
    /// reads it again.
    private func retryRefused() {
        for name in entries.keys {
            if case .limitExceeded = entries[name]?.failure {
                entries[name]?.failure = nil
            }
        }
    }

    private func totalBytes() -> Int {
        entries.values.reduce(0) { $0 + ($1.content?.byteSize ?? 0) }
    }

    private func neededByAnyClient() -> Set<String> {
        Set(clients.values.flatMap(\.needed))
    }

    private func changeHandlers() -> [@Sendable () -> Void] {
        clients.values.map(\.onChange)
    }
}
