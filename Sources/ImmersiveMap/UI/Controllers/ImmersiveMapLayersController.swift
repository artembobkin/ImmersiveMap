// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Holds the layers of the app's own data a map draws (`ImmersiveMapLayer`),
/// and is the app's handle to change them. Attach it with
/// `ImmersiveMapView.layers(_:)`:
///
///     @State private var layers = ImmersiveMapLayersController()
///
///     ImmersiveMapView()
///         .layers(layers)
///         .task {
///             layers.set([try ImmersiveMapLayer(id: "districts", geoJSON: data)])
///         }
///
/// The layers draw in the order the controller holds them, a later one over
/// an earlier one. An id names one layer: a layer set under an id the
/// controller already holds takes that layer's place. A changed layer is
/// prepared for the GPU off the main thread, and the map goes on drawing
/// the one it replaces until then.
///
/// Thread-safe (`@unchecked Sendable`): all mutable state is serialized by
/// `lock`, so the layers can be changed from any thread, the one that read
/// a large GeoJSON file included.
public final class ImmersiveMapLayersController: @unchecked Sendable {
    private let lock = NSLock()
    private var orderedLayers: [ImmersiveMapLayer] = []
    private var changeHandler: (() -> Void)?
    private weak var changeHandlerOwner: AnyObject?

    public init(_ layers: [ImmersiveMapLayer] = []) {
        orderedLayers = Self.uniqued(layers)
    }

    /// The layers as they are now, in the order they draw.
    public var layers: [ImmersiveMapLayer] {
        lock.lock()
        defer { lock.unlock() }
        return orderedLayers
    }

    /// The layer with `id`, nil when the controller holds none.
    public func layer(id: String) -> ImmersiveMapLayer? {
        lock.lock()
        defer { lock.unlock() }
        return orderedLayers.first { $0.id == id }
    }

    /// Replaces every layer. A layer left out is let go, with what the map
    /// had prepared of it.
    public func set(_ layers: [ImmersiveMapLayer]) {
        mutate { $0 = Self.uniqued(layers) }
    }

    /// Puts each layer in the place of the one with its id, or after the
    /// last layer when the controller holds none with that id.
    public func upsert(_ layers: [ImmersiveMapLayer]) {
        mutate { ordered in
            for layer in layers {
                if let index = ordered.firstIndex(where: { $0.id == layer.id }) {
                    ordered[index] = layer
                } else {
                    ordered.append(layer)
                }
            }
        }
    }

    public func upsert(_ layer: ImmersiveMapLayer) {
        upsert([layer])
    }

    public func remove(ids: [String]) {
        let ids = Set(ids)
        mutate { $0.removeAll { ids.contains($0.id) } }
    }

    public func remove(id: String) {
        remove(ids: [id])
    }

    public func clear() {
        mutate { $0.removeAll() }
    }

    /// Shows or hides a layer. A hidden layer keeps what the map prepared
    /// of it, so showing it again is immediate.
    public func setVisible(id: String, _ isVisible: Bool) {
        mutate { ordered in
            guard let index = ordered.firstIndex(where: { $0.id == id }) else { return }
            ordered[index].isVisible = isVisible
        }
    }

    // MARK: - The map view's side

    func setChangeHandler(_ handler: (() -> Void)?, owner: AnyObject) {
        lock.lock()
        changeHandler = handler
        changeHandlerOwner = owner
        lock.unlock()
    }

    /// Clears the handler only if `owner` still owns it: tearing down an old
    /// host view must not detach the controller from a new view that has
    /// already rebound it to itself.
    func clearChangeHandler(ownedBy owner: AnyObject) {
        lock.lock()
        if changeHandlerOwner === owner {
            changeHandler = nil
            changeHandlerOwner = nil
        }
        lock.unlock()
    }

    /// Applies `change`, and tells the map when it left the layers other
    /// than they were: setting the same layers again asks for no frame.
    private func mutate(_ change: (inout [ImmersiveMapLayer]) -> Void) {
        lock.lock()
        let before = orderedLayers
        change(&orderedLayers)
        let changeHandler = orderedLayers == before ? nil : changeHandler
        lock.unlock()

        changeHandler?()
    }

    /// The layers with one layer to an id: the last one given under an id,
    /// in the place of the first.
    private static func uniqued(_ layers: [ImmersiveMapLayer]) -> [ImmersiveMapLayer] {
        var indexById: [String: Int] = [:]
        var result: [ImmersiveMapLayer] = []
        for layer in layers {
            if let index = indexById[layer.id] {
                result[index] = layer
            } else {
                indexById[layer.id] = result.count
                result.append(layer)
            }
        }
        return result
    }
}
