// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// Holds the app's own data a map draws, and is the app's handle to change
/// it. The data is registered once, under a name, and the layers say which
/// of it to draw and how (`ImmersiveMapLayer`). Attach the controller with
/// `ImmersiveMapView.layers(_:)`:
///
///     @State private var layers = ImmersiveMapLayersController()
///
///     ImmersiveMapView()
///         .layers(layers)
///         .task {
///             layers.register("districts", geoJSONFile: districtsURL)
///             layers.register("parks", geoJSON: parksData, identity: "2026-11")
///             layers.set([ImmersiveMapLayer(source: "districts")])
///         }
///
/// A registered source costs nothing until a layer draws it: it is then
/// read off the main thread, so an app can register every file it has and
/// draw the few the user picks. A layer is prepared for the GPU once and
/// kept on disk (`cacheLimitBytes`), so the next launch draws it without
/// reading its source. The shapes that are read are let go
/// once the layer is prepared, unless the app listens to taps on its
/// layers, and are bounded by `inputLimitBytes`. A source that cannot be read, or does not fit, is
/// reported to `onSourceFailed`.
///
/// The layers draw in the order the controller holds them, a later one over
/// an earlier one. An id names one layer: a layer set under an id the
/// controller already holds takes that layer's place. A changed layer is
/// prepared for the GPU off the main thread, and the map goes on drawing
/// the one it replaces until then.
///
/// Thread-safe (`@unchecked Sendable`): all mutable state is serialized by
/// `lock`, so the sources and the layers can be changed from any thread.
public final class ImmersiveMapLayersController: @unchecked Sendable {
    /// The input limit of a controller that is given none: 64 MB, about
    /// four million coordinates.
    public static let defaultInputLimitBytes = 64 * 1024 * 1024

    /// The most memory the shapes that are read may take at one time, in
    /// bytes: 16 for a coordinate and a small fixed cost for a shape. Over
    /// it, the source drawn last in the layers' order is refused
    /// (`ImmersiveMapLayerSourceError.limitExceeded`). Raise it for an app
    /// whose data is larger, lower it on a device short of memory.
    public var inputLimitBytes: Int { library.limitBytes }

    /// Called on the main thread when a source a layer draws cannot be
    /// read, or does not fit the input limit, with the source's name.
    public var onSourceFailed: (@Sendable (String, ImmersiveMapLayerSourceError) -> Void)? {
        didSet { library.setFailureHandler(onSourceFailed) }
    }

    /// The registered sources and the ones that are read, shared with
    /// every map that draws this controller's layers.
    let library: LayerSourceLibrary

    private let lock = NSLock()
    private var orderedLayers: [ImmersiveMapLayer] = []
    private var changeHandler: (() -> Void)?
    private weak var changeHandlerOwner: AnyObject?

    /// The disk cache limit of a controller that is given none: 256 MB.
    public static let defaultCacheLimitBytes = 256 * 1024 * 1024

    /// The most disk the prepared layers may take, in bytes. A layer is
    /// prepared for the GPU once and kept in the app's Caches directory,
    /// so the next launch draws it without reading its source again. The layers used least recently are deleted over the
    /// limit, and zero keeps nothing.
    public var cacheLimitBytes: Int { library.meshCache.limitBytes }

    public convenience init(_ layers: [ImmersiveMapLayer] = [],
                            inputLimitBytes: Int = ImmersiveMapLayersController.defaultInputLimitBytes,
                            cacheLimitBytes: Int = ImmersiveMapLayersController.defaultCacheLimitBytes) {
        self.init(layers, inputLimitBytes: inputLimitBytes, meshCache: LayerMeshDiskCache(limitBytes: cacheLimitBytes))
    }

    /// A controller over a cache given to it, which a test keeps in a
    /// directory of its own.
    init(_ layers: [ImmersiveMapLayer], inputLimitBytes: Int, meshCache: LayerMeshDiskCache) {
        library = LayerSourceLibrary(limitBytes: inputLimitBytes, meshCache: meshCache)
        orderedLayers = Self.uniqued(layers)
    }

    // MARK: - Sources

    /// Registers the GeoJSON document (RFC 7946) in the file at `url`
    /// under `name`: a FeatureCollection, a Feature, a GeometryCollection
    /// or a bare geometry. Polygons and MultiPolygons are zones,
    /// LineStrings and MultiLineStrings lines, Points and MultiPoints
    /// points. A feature's simplestyle properties (`fill`, `fill-opacity`,
    /// `stroke`, `stroke-opacity`, `stroke-width`, `marker-color`,
    /// `marker-size`, `marker-radius`) are laid over the style of the layer
    /// that draws it. The file is read when a layer first draws the
    /// source, and may be read again later, so it has to stay where it is.
    public func register(_ name: String, geoJSONFile url: URL) {
        library.register(name, .geoJSONFile(url))
    }

    /// Registers a GeoJSON document held in memory under `name`, read as a
    /// file's is. `identity` names this data, and is the app's to choose:
    /// a version, a date, an ETag. The map never looks into the data to
    /// tell whether it changed. The same identity is the same data, so it
    /// is not read again and a layer prepared from it in an earlier launch
    /// is loaded from disk. Give other data another identity, or the map
    /// goes on drawing the old.
    public func register(_ name: String, geoJSON data: Data, identity: String) {
        library.register(name, .geoJSON(data, identity: identity))
    }

    /// Registers shapes built in code under `name`. `identity` names this
    /// data, as for a GeoJSON document held in memory: the same identity
    /// is the same shapes, and other shapes need another one.
    public func register(_ name: String,
                         identity: String,
                         polygons: [ImmersiveMapPolygon] = [],
                         polylines: [ImmersiveMapPolyline] = [],
                         points: [ImmersiveMapPoint] = []) {
        library.register(name, .shapes(polygons: polygons, polylines: polylines, points: points, identity: identity))
    }

    /// Removes a source. A layer that names it draws nothing until a
    /// source is registered under the name again.
    public func unregister(_ name: String) {
        library.unregister(name)
    }

    /// The names of the registered sources, in alphabetical order.
    public var sourceNames: [String] { library.names }

    /// Why the source cannot be drawn, nil when it can or was not tried.
    public func failure(ofSource name: String) -> ImmersiveMapLayerSourceError? {
        library.failure(of: name)
    }

    // MARK: - Layers

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
    /// of it while memory allows, so showing it again is immediate.
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
