# 3D scene models

Anchor 3D models (USDZ or OBJ) to geographic coordinates with the `.sceneModels(...)` modifier and `ImmersiveMapSceneModelsController`. Models render inside the map world pass (with real depth, MSAA, and the same light as extruded buildings) in flat mode, on the globe, and through the globe-to-flat morph: a model sticks to the surface, tilts with the sphere, scales with zoom, and disappears behind the globe horizon. Map labels never paint over a model: a depth-only replay of the drawn models opens the overlay pass, and label fragments depth-test against it, so model silhouettes clip them.

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
| `source` | `Source(url:)` with a local file URL, or `Source(resource:withExtension:in:)` for a bundle asset. Models sharing a source share one loaded mesh. Remote URLs are not supported, download to a file first. |
| `coordinate` | Geographic anchor in degrees. The model's asset-space origin lands on this point of the map surface. |
| `altitudeMeters` | Lifts the model along the local up vector (sphere normal on the globe, +Z in flat mode), e.g. an airplane at cruising altitude. |
| `headingDegrees` / `pitchDegrees` / `rollDegrees` | Orientation in the local tangent frame. At zero the asset's −Z faces north and +Y points up (the USD Y-up convention is converted automatically). |
| `scale` | Multiplier over real-world meters. Model I/O does not expose the USD stage `metersPerUnit`, so one asset unit is presented as one meter. |
| `fitDiameterMeters` | Uniformly rescales the asset so the largest extent of its bounding box spans this many meters (applied before `scale`), the easy way to place an arbitrary asset at a sensible size. |

## Sizing

Models are sized in real-world meters with the Web-Mercator convention: on the flat map a model inflates by `1/cos(latitude)` together with the surrounding geometry, on the globe it keeps true scale, and through the morph the two blend continuously. Sizes re-normalize with zoom automatically: a 10-meter model is subpixel at low zoom by design; use `fitDiameterMeters` for landmark-scale content that should read from far away.

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

    public func animate(id:along:duration:curve:appliesHeading:appliesPitch:completion:)
    public func cancelPathAnimation(id: UInt64)
}
```

The controller is thread-safe and can be mutated from any thread. Rendering stays on-demand: an idle map with idle models costs nothing; every mutation renders exactly the frames it needs.

- `move` animates along a great circle with a duration derived from the distance (snappy for short hops, capped for jumps), the same feel as avatar movement.
- `setOrientation` / `setScale` / `setAltitude` ease over `duration` (default 0.3 s); orientation interpolates as a shortest-arc quaternion. Pass `duration: 0` to snap.
- `upsert` / `set` replace descriptors without transform animation; coordinate changes of surviving ids still glide.
- `animate(id:along:duration:)` flies a model along an `ImmersiveMapGeoPath`, see the next section.

## Flying a model along a path

```swift
public func animate(id: UInt64,
                    along path: ImmersiveMapGeoPath,
                    duration: TimeInterval,
                    curve: ImmersiveMapPathAnimationCurve = .easeOut,
                    appliesHeading: Bool = true,
                    appliesPitch: Bool = true,
                    completion: ((Bool) -> Void)? = nil)

public func cancelPathAnimation(id: UInt64)
```

`animate` moves an existing scene model along the path over `duration` seconds. That is the API to use for anything longer than a hop: `move` derives its duration from the distance and caps it below a second. With `appliesHeading` the model turns to face along the trajectory (course clockwise from north); with `appliesPitch` it tilts nose up while the altitude profile climbs and nose down while it descends. `curve` is `.easeOut` (leaves at full speed and settles onto the destination) or `.linear` (constant ground speed).

`completion` fires exactly once on the main thread: `true` when the model reached the end of the path, `false` when the animation was superseded by another `animate` for the same id, cancelled, or dropped because the model was removed, the map view went away, or the renderer was recreated by a settings change. That makes it safe to chain legs of a journey without leaking a waiting continuation.

While the animation runs the path owns the model's coordinate, altitude and, when the flags are set, heading and pitch: `move`, `setAltitude` and `setOrientation` for that id are ignored for as long as it runs, and do not resurface when it ends. Everything else, `setScale` included, still applies. `cancelPathAnimation(id:)` leaves the model where the flight got to, and the engine writes that position back into the descriptor, so a later mutation starts from where the model actually is.

Note that this is not limited to the globe: the model animation works in flat presentation and through the morph. To draw the same path as a line see [routes](routes.md) (globe only), and to send the camera along it see [travelling the camera along a path](camera-path-follow.md). The three share one `ImmersiveMapGeoPath` and one duration, and nothing passes between them at runtime.

## Taps and selection

`.onSceneModelTap { }` delivers a tap that lands on a model:

```swift
ImmersiveMapView()
    .sceneModels(sceneModels)
    .onSceneModelTap { event in
        print("tapped \(event.model.id) at \(event.coordinate)")
    }
```

```swift
public struct ImmersiveMapSceneModelTapEvent {
    public let model: ImmersiveMapSceneModel   // descriptor at the moment of the tap
    public let coordinate: GeoCoordinate       // where the model was DRAWN
    public let screenPoint: CGPoint            // in map view coordinates
}
```

The tap is resolved against the model's bounding box exactly where the frame drew it: the ray is the inverse of the projection the model's vertex shader ran, so hit areas follow the model through flat mode, the globe, the morph between them, and any animation, with no per-model bookkeeping in the app. `coordinate` is where the model *is*, which during `animate(id:along:)` is a point on the flight while `model.coordinate` already holds the path's destination.

Resolution rules:

- **Nearest wins.** Overlapping models resolve to the one closest to the camera.
- **Avatars first.** Avatar markers are screen-space overlays drawn over the world pass, so one covering a model takes the tap. A model behind the globe horizon is not tappable at all.
- **Oriented, not spherical.** The box is tested in the model's own space, so a diagonal aircraft has a hit area the shape of the aircraft rather than a ball of empty air around it.
- **Minimum touch target.** A model whose whole on-screen footprint is smaller than 44 pt grows to that size around its center, so distant models stay reachable by finger. A model large enough to aim at keeps its own outline, so this can never steal a tap from geometry you actually hit.

Models also take part in `ImmersiveMapSelectionController` as `ImmersiveMapSelection.Kind.sceneModel`, alongside avatars: a tap selects, a tap on the background clears, and removing a selected model clears it. Selection carries no appearance of its own for models: the engine draws the asset as authored, and highlighting the selected one is the app's to do (swap the source, nudge the scale, draw a SwiftUI marker over it).

## Loading and memory

Assets load asynchronously off the main thread via Model I/O (`MDLAsset` → `MTKMesh`); the map renders the model on the first frame after the mesh is ready. Failed loads retry up to 3 times with a growing cooldown. Loaded meshes live in a memory cache (~128 MB) keyed by source URL: models currently on the map are protected from eviction, everything else is dropped under memory pressure and reloads on demand.

Materials: the base color of each submesh is used (either its texture or its constant color), lit by the same fixed light as extruded buildings (ambient + diffuse + specular). Skeletal/USD animations are not played; meshes are static, movement comes from the controller API.

## Limitations

- **Translucent buildings** (`buildingExtrusionMode: .translucent`, or `.solidAtHighZoom` below its end zoom): the composited building tint carries no depth, so models are never occluded by translucent buildings (and never tinted by them). With the default `.solid` (and `.solidAtHighZoom` at high zoom), occlusion between models and buildings is depth-correct, see [buildings and shadows](buildings-and-shadows.md).
- **Video export**: scene models are not included in [tour video exports](tour-video-export.md) in this version.
- **Antimeridian**: a model is drawn once (its anchor wraps to the camera-near copy of the world), not duplicated on both screen edges.
- **Tap precision**: hit-testing uses the asset's bounding box, not its triangles, so a tap in the empty corner of the box of a concave model still counts as a hit. Depth is not consulted either: a model hidden behind a solid building is still tappable (the globe horizon is handled, such a model is not). See [tap selection](selection.md).

Running examples: [`Examples/macOS/ImmersiveMapSceneModelsMac`](../../Examples/macOS/ImmersiveMapSceneModelsMac) places USDZ and OBJ models and drives the live transform API; [`Examples/macOS/ImmersiveMapRoutesMac`](../../Examples/macOS/ImmersiveMapRoutesMac) flies one along a path.
