// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

/// Process-wide immutable GPU resources shared by every renderer instance.
///
/// A new `ImmersiveMapView` used to rebuild all of this from scratch: the
/// shader library load, ~26 pipeline states, the MSDF text atlases (two raw
/// pixel uploads and two JSON metric decodes), the POI sprite
/// rasterization, and the procedural sphere/cap geometry. None of it depends
/// on anything that varies between views but the sample count: the device is
/// the system singleton and the color format is always `bgra8Unorm`, so one
/// set per sample count serves the whole process and a second map view (or a
/// settings-driven renderer recreation) skips the entire cost.
///
/// The class names no feature. What it holds is a list of sets, each a
/// feature's own (`SharedGPUResources`, declared in the feature's folder),
/// and the list is `RenderGraphFactory.sharedResourceTypes`: a feature's
/// subsystem is handed its set by the factory, which reads it with
/// `get(_:)`. A new shared resource is a new set, or a new field of one,
/// and nothing here changes.
///
/// Everything held here is immutable after creation and is safe to read from
/// any thread (Metal objects are thread-safe for use; the Swift wrappers never
/// mutate after init). The cache itself is `@MainActor` because every renderer
/// creation path already runs on the main actor; the build behind it runs
/// on a detached task (`resources(sampleCount:)`, `prewarm(sampleCount:)`),
/// so the first map view of a process, or an app that prewarms at launch,
/// never stalls the main thread on shader pipelines and atlases.
///
/// Deliberate trade-offs of process-lifetime caching:
/// - The set stays resident after the last map view goes away (the decoded
///   text atlases dominate at ~2×17 MB of private textures). That is the
///   point (the next view starts warm), but apps where the map is a rarely
///   visited screen pay the residency; a release-when-idle hook can be added
///   if that ever matters in practice.
/// - The device is resolved once. If the system default device can change
///   mid-process (Intel macOS with an external GPU), later renderers keep the
///   original device, unlike the old per-view bootstrap which re-resolved it.
@MainActor
final class SharedRenderResources {
    let device: MTLDevice
    let library: MTLLibrary
    let renderSampleCount: Int
    /// The one color format the engine renders in. `RendererSetup` stamps it
    /// onto every view's layer.
    let colorPixelFormat: MTLPixelFormat = .bgra8Unorm

    /// The sets, each under its own type. Written once, in `init`, and
    /// only read after it, from whichever thread a renderer is made on.
    private nonisolated(unsafe) let sets: [ObjectIdentifier: Any]

    /// A feature's shared set. The type is one of
    /// `RenderGraphFactory.sharedResourceTypes`.
    nonisolated func get<Set: SharedGPUResources>(_ type: Set.Type) -> Set {
        set(type)
    }

    /// A shared set that was made on the main thread, one of
    /// `RenderGraphFactory.mainThreadSharedResourceTypes`.
    nonisolated func get<Set: MainThreadSharedGPUResources>(_ type: Set.Type) -> Set {
        set(type)
    }

    private nonisolated func set<Set>(_ type: Set.Type) -> Set {
        guard let set = sets[ObjectIdentifier(type)] as? Set else {
            fatalError("\(type) is not listed among the shared render resources of RenderGraphFactory")
        }
        return set
    }

    // MARK: - Lifecycle

    private static var cached: [Int: SharedRenderResources] = [:]
    /// The builds in progress, one per resolved sample count, so a prewarm
    /// and the first map view that arrives while it runs share one build.
    private static var inFlight: [Int: Task<SharedRenderResources, any Error>] = [:]
    /// Metal objects are thread-safe; the box carries the device into the
    /// background build under strict concurrency.
    private struct DeviceBox: @unchecked Sendable {
        let device: MTLDevice
    }
    private static let sharedDevice: DeviceBox? = MTLCreateSystemDefaultDevice().map(DeviceBox.init)

    private static func resolvedSampleCount(_ sampleCount: Int) -> (device: MTLDevice, sampleCount: Int) {
        guard let box = sharedDevice else {
            fatalError("Metal is not supported on this device")
        }
        return (box.device, RendererSetup.resolvedRenderSampleCount(requested: sampleCount, metalDevice: box.device))
    }

    /// Returns the process-wide instance for a sample count, creating it on
    /// the calling thread when nothing has built it yet. The count is the
    /// one the device can actually render with
    /// (`RendererSetup.resolvedRenderSampleCount`), so two requests the
    /// device resolves alike share one set. The synchronous path: the
    /// offscreen recorders and the tests take it; a map view goes through
    /// `resources(sampleCount:)` so the build never blocks the main thread.
    /// Throws when the engine's resources cannot be found
    /// (`ImmersiveMapResourceBundle.NotFound`, `RenderResourcesError`), and
    /// a later call tries again.
    static func shared(sampleCount: Int = 1) throws -> SharedRenderResources {
        let (device, resolved) = resolvedSampleCount(sampleCount)
        if let cached = cached[resolved] {
            return cached
        }
        let resources = SharedRenderResources(built: try Self.build(device: device, renderSampleCount: resolved))
        cached[resolved] = resources
        return resources
    }

    /// Whether `shared(sampleCount:)` would return without building.
    static func isAvailable(sampleCount: Int = 1) -> Bool {
        cached[resolvedSampleCount(sampleCount).sampleCount] != nil
    }

    /// The process-wide instance for a sample count, built off the main
    /// thread when it does not exist yet: the shader library, the pipeline
    /// states (which is where the device compiles the shaders, once per
    /// build, the system caching the binaries after that), the atlases and
    /// the geometry come together on a detached task, and only the SF
    /// Symbol sprite atlas, which rasterizes through UIImage/NSImage, is
    /// made here at the end. Concurrent callers await the same build; a
    /// synchronous `shared` call that lands in the meantime builds its own
    /// copy and wins, and the awaited build is then dropped in its favour.
    /// Throws as `shared(sampleCount:)` does, to every caller awaiting the
    /// build, and a later call tries again.
    static func resources(sampleCount: Int = 1) async throws -> SharedRenderResources {
        let (device, resolved) = resolvedSampleCount(sampleCount)
        if let cached = cached[resolved] {
            return cached
        }
        if let inFlight = inFlight[resolved] {
            return try await inFlight.value
        }
        let box = DeviceBox(device: device)
        let task = Task { @MainActor () throws -> SharedRenderResources in
            let built: Built
            do {
                built = try await Task.detached(priority: .userInitiated) {
                    try Self.build(device: box.device, renderSampleCount: resolved)
                }.value
            } catch {
                inFlight[resolved] = nil
                throw error
            }
            if let cached = cached[resolved] {
                inFlight[resolved] = nil
                return cached
            }
            let resources = SharedRenderResources(built: built)
            cached[resolved] = resources
            inFlight[resolved] = nil
            return resources
        }
        inFlight[resolved] = task
        return try await task.value
    }

    /// Builds the resources for a sample count ahead of the first map view,
    /// off the main thread; see `resources(sampleCount:)`. Returns when
    /// they are ready, or when the build failed: the map view that needs
    /// them builds again and shows the error.
    static func prewarm(sampleCount: Int = 1) async {
        _ = try? await resources(sampleCount: sampleCount)
    }

    #if DEBUG
    /// Forgets the built set for a sample count, so a test can watch it
    /// being built again. Engines holding the old set keep it.
    static func dropCachedForTesting(sampleCount: Int) {
        let resolved = resolvedSampleCount(sampleCount).sampleCount
        cached[resolved] = nil
        inFlight[resolved] = nil
    }
    #endif
    /// Everything the build makes away from the main actor: immutable
    /// Metal objects and the sets that hold them, which are safe to hand
    /// across threads.
    private struct Built: @unchecked Sendable {
        let device: MTLDevice
        let library: MTLLibrary
        let renderSampleCount: Int
        let sets: [ObjectIdentifier: Any]
    }

    private nonisolated static func build(device: MTLDevice, renderSampleCount: Int) throws -> Built {
        // The bundle first: the text atlases and the pin are read
        // from it whichever library the shaders come from.
        let resourceBundle = try ImmersiveMapResourceBundle.bundle()
        let library = try RendererSetup.makeLibrary(metalDevice: device, bundle: resourceBundle)
        let sets = makeSets(RenderGraphFactory.sharedResourceTypes,
                            build: SharedGPUResourceBuild(device: device,
                                                          library: library,
                                                          resourceBundle: resourceBundle,
                                                          pixelFormat: .bgra8Unorm,
                                                          sampleCount: renderSampleCount))
        return Built(device: device,
                     library: library,
                     renderSampleCount: renderSampleCount,
                     sets: sets)
    }

    private init(built: Built) {
        self.device = built.device
        self.library = built.library
        self.renderSampleCount = built.renderSampleCount
        var sets = built.sets
        // What rasterizes through UIImage/NSImage stays on the main
        // thread rather than joining the background build.
        for type in RenderGraphFactory.mainThreadSharedResourceTypes {
            sets[ObjectIdentifier(type)] = type.make(device: built.device)
        }
        self.sets = sets
    }

    // MARK: - Concurrent build

    /// Makes the listed sets side by side. A set's construction touches
    /// only the device, the library and the bundle, so it is safe off the
    /// main thread. Metal compiles pipeline states concurrently, so
    /// building the independent sets in parallel cuts the main cost of
    /// renderer startup. Each iteration writes exactly one slot of its
    /// own, and `concurrentPerform` returns only after all iterations
    /// finished, so the collection at the end observes fully initialized
    /// values. The set of created resources and the
    /// synchronous-before-first-frame contract do not depend on the order.
    private nonisolated static func makeSets(_ types: [any SharedGPUResources.Type],
                                             build: SharedGPUResourceBuild) -> [ObjectIdentifier: Any] {
        let slots = UnsafeMutablePointer<Any?>.allocate(capacity: types.count)
        slots.initialize(repeating: nil, count: types.count)
        defer {
            slots.deinitialize(count: types.count)
            slots.deallocate()
        }
        // Each job writes its own slot, so the jobs run side by side
        // with nothing shared between them.
        nonisolated(unsafe) let jobSlots = slots
        nonisolated(unsafe) let jobTypes = types
        DispatchQueue.concurrentPerform(iterations: types.count) { index in
            jobSlots[index] = jobTypes[index].make(build)
        }
        var sets: [ObjectIdentifier: Any] = [:]
        for (index, type) in types.enumerated() {
            sets[ObjectIdentifier(type)] = slots[index]
        }
        return sets
    }
}
