// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal

/// The GPU binaries of the engine's pipelines, so that creating a pipeline
/// state is a lookup instead of a shader compilation.
///
/// The system caches the binaries it compiles, so a pipeline compiles once
/// per device per build: the first launch after every install or update of
/// the app, on the first map screen, for every pipeline at once. The package
/// ships that first compilation done: `ImmersiveMapPipelines.metallib`, a
/// Metal binary archive built offline by `Tools/PipelineArchive` from the
/// harvested pipeline descriptors and the compiled shader library, for the
/// GPU families the script names. Every pipeline descriptor the engine
/// creates goes through `makeArchivedRenderPipelineState` /
/// `makeArchivedComputePipelineState`, which attach the shipped archive;
/// Metal takes the binary when the archive holds one for this GPU and this
/// descriptor and compiles from the AIR otherwise, so a stale or missing
/// archive costs nothing but the compilation it would have saved.
///
/// The same seam records descriptors for the offline build: while a harvest
/// is open every descriptor is also added to a fresh archive that
/// `endHarvest` serializes, which is how the script obtains the pipeline
/// script (`metal-source` extracts it from that file).
///
/// One registry per process, keyed by device; the lock keeps the registry
/// itself consistent, the Metal objects are thread-safe on their own.
enum MetalPipelineArchives {
    /// The shipped archive's resource name (the extension is `metallib`).
    static let shippedResourceName = "ImmersiveMapPipelines"

    /// What the shipped archive did for the pipelines created so far: a hit
    /// is a state Metal built from a stored binary, a miss one it compiled.
    struct Statistics: Equatable, Sendable {
        var hits = 0
        var misses = 0
        /// Pipelines created while no archive was loaded at all.
        var unarchived = 0
    }

    private struct DeviceState {
        var shipped: MTLBinaryArchive?
        var shippedLoadAttempted = false
        var harvest: MTLBinaryArchive?
        var statistics = Statistics()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [ObjectIdentifier: DeviceState] = [:]
    /// Where the shipped archive is looked up; tests point it elsewhere.
    nonisolated(unsafe) private static var shippedArchiveURLProvider: () -> URL? = {
        Bundle.module.url(forResource: shippedResourceName, withExtension: "metallib")
    }

    // MARK: - Lookup

    /// The shipped archive for the device, loaded on first use; nil when the
    /// package carries none or the device cannot open it.
    static func shippedArchive(for device: MTLDevice) -> MTLBinaryArchive? {
        lock.lock()
        defer { lock.unlock() }
        var state = states[ObjectIdentifier(device), default: DeviceState()]
        if state.shippedLoadAttempted == false {
            state.shippedLoadAttempted = true
            if let url = shippedArchiveURLProvider() {
                let descriptor = MTLBinaryArchiveDescriptor()
                descriptor.url = url
                state.shipped = try? device.makeBinaryArchive(descriptor: descriptor)
            }
            states[ObjectIdentifier(device)] = state
        }
        return state.shipped
    }

    static func statistics(for device: MTLDevice) -> Statistics {
        lock.lock()
        defer { lock.unlock() }
        return states[ObjectIdentifier(device)]?.statistics ?? Statistics()
    }

    // MARK: - Harvest

    /// Starts recording every descriptor created on the device into a fresh
    /// archive. The shipped archive stays attached, so a harvest run also
    /// reports its hits and misses.
    static func beginHarvest(device: MTLDevice) throws {
        let archive = try device.makeBinaryArchive(descriptor: MTLBinaryArchiveDescriptor())
        lock.lock()
        defer { lock.unlock() }
        states[ObjectIdentifier(device), default: DeviceState()].harvest = archive
    }

    /// Writes the harvested archive to `url` and stops recording.
    static func endHarvest(device: MTLDevice, writingTo url: URL) throws {
        lock.lock()
        let archive = states[ObjectIdentifier(device)]?.harvest
        states[ObjectIdentifier(device)]?.harvest = nil
        lock.unlock()
        guard let archive else {
            throw HarvestError.noHarvestInProgress
        }
        try archive.serialize(to: url)
    }

    enum HarvestError: Error {
        case noHarvestInProgress
    }

    // MARK: - Pipeline creation

    fileprivate static func harvestArchive(for device: MTLDevice) -> MTLBinaryArchive? {
        lock.lock()
        defer { lock.unlock() }
        return states[ObjectIdentifier(device)]?.harvest
    }

    fileprivate static func record(hit: Bool?, device: MTLDevice) {
        lock.lock()
        defer { lock.unlock() }
        var state = states[ObjectIdentifier(device), default: DeviceState()]
        switch hit {
        case .some(true): state.statistics.hits += 1
        case .some(false): state.statistics.misses += 1
        case .none: state.statistics.unarchived += 1
        }
        states[ObjectIdentifier(device)] = state
    }

    // MARK: - Test support

    /// Points the shipped-archive lookup at another file (or at nothing) and
    /// forgets every device's loaded archive and statistics. Tests only.
    static func resetForTesting(shippedArchiveURL: URL?) {
        lock.lock()
        defer { lock.unlock() }
        states.removeAll()
        shippedArchiveURLProvider = { shippedArchiveURL }
    }

    /// Restores the bundle lookup after `resetForTesting`.
    static func restoreShippedArchiveLookupForTesting() {
        lock.lock()
        defer { lock.unlock() }
        states.removeAll()
        shippedArchiveURLProvider = {
            Bundle.module.url(forResource: shippedResourceName, withExtension: "metallib")
        }
    }
}

extension MTLDevice {
    /// `makeRenderPipelineState(descriptor:)` through the shipped archive:
    /// the state comes from a stored binary when the archive has one, from a
    /// compilation otherwise, and a harvest in progress records the
    /// descriptor either way.
    func makeArchivedRenderPipelineState(descriptor: MTLRenderPipelineDescriptor) throws -> MTLRenderPipelineState {
        if let harvest = MetalPipelineArchives.harvestArchive(for: self) {
            try harvest.addRenderPipelineFunctions(descriptor: descriptor)
        }
        guard let shipped = MetalPipelineArchives.shippedArchive(for: self) else {
            MetalPipelineArchives.record(hit: nil, device: self)
            return try makeRenderPipelineState(descriptor: descriptor)
        }
        descriptor.binaryArchives = [shipped]
        // The miss is observed rather than guessed: Metal says nothing about
        // where a state came from, but it fails fast when asked to only take
        // binaries, and a stored binary makes that call as cheap as a lookup.
        if let state = try? makeRenderPipelineState(descriptor: descriptor,
                                                    options: .failOnBinaryArchiveMiss,
                                                    reflection: nil) {
            MetalPipelineArchives.record(hit: true, device: self)
            return state
        }
        MetalPipelineArchives.record(hit: false, device: self)
        return try makeRenderPipelineState(descriptor: descriptor)
    }

    /// `makeComputePipelineState(function:)` through the shipped archive;
    /// see `makeArchivedRenderPipelineState`.
    func makeArchivedComputePipelineState(function: MTLFunction) throws -> MTLComputePipelineState {
        let descriptor = MTLComputePipelineDescriptor()
        descriptor.computeFunction = function
        if let harvest = MetalPipelineArchives.harvestArchive(for: self) {
            try harvest.addComputePipelineFunctions(descriptor: descriptor)
        }
        guard let shipped = MetalPipelineArchives.shippedArchive(for: self) else {
            MetalPipelineArchives.record(hit: nil, device: self)
            return try makeComputePipelineState(function: function)
        }
        descriptor.binaryArchives = [shipped]
        if let state = try? makeComputePipelineState(descriptor: descriptor,
                                                     options: .failOnBinaryArchiveMiss,
                                                     reflection: nil) {
            MetalPipelineArchives.record(hit: true, device: self)
            return state
        }
        MetalPipelineArchives.record(hit: false, device: self)
        return try makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
    }
}
