// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal

/// A layer on the GPU: its buffers and the chunks that draw from them
/// (`LayerMeshBuilder`). Immutable after creation, so it is shared between
/// the build that makes it and the frames that draw it (`@unchecked
/// Sendable`: Metal objects are safe to use from any thread, and nothing
/// here changes).
final class LayerMesh: @unchecked Sendable {
    let key: LayerMeshKey
    let fillVertices: MTLBuffer?
    let fillIndices: MTLBuffer?
    let lineVertices: MTLBuffer?
    let lineIndices: MTLBuffer?
    let discs: MTLBuffer?
    let chunks: [LayerMeshChunk]

    init?(key: LayerMeshKey, data: LayerMeshData, device: MTLDevice) {
        func buffer<Element>(_ values: [Element], label: String) -> MTLBuffer? {
            guard values.isEmpty == false else { return nil }
            let buffer = values.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
            }
            buffer?.label = label
            return buffer
        }
        self.key = key
        fillVertices = buffer(data.fillVertices, label: "Layer fill vertices")
        fillIndices = buffer(data.fillIndices, label: "Layer fill indices")
        lineVertices = buffer(data.lineVertices, label: "Layer line vertices")
        lineIndices = buffer(data.lineIndices, label: "Layer line indices")
        discs = buffer(data.discs, label: "Layer discs")
        chunks = data.chunks
        let complete = (data.fillIndices.isEmpty || (fillVertices != nil && fillIndices != nil))
            && (data.lineIndices.isEmpty || (lineVertices != nil && lineIndices != nil))
            && (data.discs.isEmpty || discs != nil)
        guard complete else { return nil }
    }
}

/// Holds the layers of the app's data on the GPU for the frames. A layer
/// whose data or styles changed (`ImmersiveMapLayer.meshKey`) is built
/// again off the main thread, and the frames go on drawing its last mesh
/// until the new one is ready, which asks for a frame through
/// `eventSink`. A layer no longer set is let go. The state is serialized
/// by a queue: the frames read it on the main thread, the builds write it
/// from theirs.
final class LayerMeshStore: @unchecked Sendable {
    private let device: MTLDevice
    private let queue = DispatchQueue(label: "ImmersiveMap.LayerMeshStore")
    private var meshes: [String: LayerMesh] = [:]
    private var building: [String: LayerMeshKey] = [:]
    weak var eventSink: RenderFrameEventSink?

    init(device: MTLDevice) {
        self.device = device
    }

    /// The meshes of `layers`, index-aligned with them, nil for a layer not
    /// yet built. Starts the builds the layers need and lets go of the
    /// meshes of the layers no longer among them.
    func meshes(for layers: [ImmersiveMapLayer]) -> [LayerMesh?] {
        var toBuild: [ImmersiveMapLayer] = []
        let result: [LayerMesh?] = queue.sync {
            let ids = Set(layers.map(\.id))
            meshes = meshes.filter { ids.contains($0.key) }
            building = building.filter { ids.contains($0.key) }
            return layers.map { layer in
                let key = layer.meshKey
                let mesh = meshes[layer.id]
                if mesh?.key != key, building[layer.id] != key {
                    building[layer.id] = key
                    toBuild.append(layer)
                }
                return mesh
            }
        }
        for layer in toBuild {
            build(layer)
        }
        return result
    }

    private func build(_ layer: ImmersiveMapLayer) {
        let device = device
        Task.detached(priority: .userInitiated) { [weak self] in
            let key = layer.meshKey
            let data = LayerMeshBuilder.build(layer: layer)
            let mesh = LayerMesh(key: key, data: data, device: device)
            guard let self else { return }
            let landed: Bool = self.queue.sync {
                guard self.building[layer.id] == key else { return false }
                self.building[layer.id] = nil
                if let mesh {
                    self.meshes[layer.id] = mesh
                }
                return mesh != nil
            }
            if landed {
                self.eventSink?.invalidate(.layerDataLoaded)
            }
        }
    }
}
