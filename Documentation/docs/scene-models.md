# 3D scene models

Anchor 3D models (USDZ or OBJ) to geographic coordinates with the `.sceneModels(...)` modifier and `ImmersiveMapSceneModelsController`. Models render inside the map world pass — with real depth, MSAA, and the same light as extruded buildings — in flat mode, on the globe, and through the globe-to-flat morph: a model sticks to the surface, tilts with the sphere, scales with zoom, and disappears behind the globe horizon.

```swift
struct MapScreen: View {
    @State private var sceneModels = ImmersiveMapSceneModelsController()

    var body: some View {
        ImmersiveMapView()
            .sceneModels(sceneModels)
            .onAppear {
                guard let source = ImmersiveMapSceneModel.Source(resource: "biplane",
                                                                 withExtension: "usdz") else { return }
                sceneModels.add(ImmersiveMapSceneModel(
                    id: 1,
                    source: source,
                    coordinate: GeoCoordinate(latitude: 48.8584, longitude: 2.2945),
                    headingDegrees: 45,
                    fitDiameterMeters: 120))
            }
    }
}
```

## Model descriptor

```swift
public struct ImmersiveMapSceneModel: Identifiable, Equatable, Sendable {
    public var id: UInt64
    public var source: Source            // local .usdz / .obj file URL
    public var coordinate: GeoCoordinate
    public var altitudeMeters: Double    // offset along the local up vector, default 0
    public var headingDegrees: Double    // clockwise from north, default 0
    public var pitchDegrees: Double      // about the local east axis, default 0
    public var rollDegrees: Double       // about the model's forward axis, default 0
    public var scale: Double             // multiplier over meters, default 1
    public var fitDiameterMeters: Double? // rescale the asset to span this many meters
}
```

| Parameter | Meaning |
|---|---|
| `source` | `Source(url:)` with a local file URL, or `Source(resource:withExtension:in:)` for a bundle asset. Models sharing a source share one loaded mesh. Remote URLs are not supported — download to a file first. |
| `coordinate` | Geographic anchor in degrees. The model's asset-space origin lands on this point of the map surface. |
| `altitudeMeters` | Lifts the model along the local up vector (sphere normal on the globe, +Z in flat mode) — e.g. an airplane at cruising altitude. |
| `headingDegrees` / `pitchDegrees` / `rollDegrees` | Orientation in the local tangent frame. At zero the asset's −Z faces north and +Y points up (the USD Y-up convention is converted automatically). |
| `scale` | Multiplier over real-world meters. Model I/O does not expose the USD stage `metersPerUnit`, so one asset unit is presented as one meter. |
| `fitDiameterMeters` | Uniformly rescales the asset so the largest extent of its bounding box spans this many meters (applied before `scale`) — the easy way to place an arbitrary asset at a sensible size. |

## Sizing

Models are sized in real-world meters with the Web-Mercator convention: on the flat map a model inflates by `1/cos(latitude)` together with the surrounding geometry, on the globe it keeps true scale, and through the morph the two blend continuously. Sizes re-normalize with zoom automatically — a 10-meter model is subpixel at low zoom by design; use `fitDiameterMeters` for landmark-scale content that should read from far away.

## Controller

```swift
public final class ImmersiveMapSceneModelsController: @unchecked Sendable {
    public func set(_ models: [ImmersiveMapSceneModel])   // full replace
    public func add(_ model: ImmersiveMapSceneModel)
    public func upsert(_ models: [ImmersiveMapSceneModel])
    public func remove(id: UInt64) / remove(ids:) / clear()

    public func move(id: UInt64, to coordinate: GeoCoordinate)
    public func setOrientation(id:headingDegrees:pitchDegrees:rollDegrees:duration:)
    public func setScale(id:_:duration:)
    public func setAltitude(id:meters:duration:)
}
```

The controller is thread-safe and can be mutated from any thread. Rendering stays on-demand: an idle map with idle models costs nothing; every mutation renders exactly the frames it needs.

- `move` animates along a great circle with a duration derived from the distance (snappy for short hops, capped for jumps) — the same feel as avatar movement.
- `setOrientation` / `setScale` / `setAltitude` ease over `duration` (default 0.3 s); orientation interpolates as a shortest-arc quaternion. Pass `duration: 0` to snap.
- `upsert` / `set` replace descriptors without transform animation; coordinate changes of surviving ids still glide.

## Loading and memory

Assets load asynchronously off the main thread via Model I/O (`MDLAsset` → `MTKMesh`); the map renders the model on the first frame after the mesh is ready. Failed loads retry up to 3 times with a growing cooldown. Loaded meshes live in a memory cache (~128 MB) keyed by source URL: models currently on the map are protected from eviction, everything else is dropped under memory pressure and reloads on demand.

Materials: the base color of each submesh is used — either its texture or its constant color — lit by the same fixed light as extruded buildings (ambient + diffuse + specular). Skeletal/USD animations are not played; meshes are static, movement comes from the controller API.

## Limitations

- **Translucent buildings** (the default `buildingExtrusionMode`): the composited building tint carries no depth, so models are never occluded by translucent buildings (and never tinted by them). With `.solid` / `.solidAtHighZoom` at high zoom, occlusion between models and buildings is depth-correct.
- **Video export**: scene models are not included in tour video exports in this version.
- **Antimeridian**: a model is drawn once (its anchor wraps to the camera-near copy of the world), not duplicated on both screen edges.
- **Selection**: models are not tappable in this version.
