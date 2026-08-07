# Routes

Draw great-circle routes over the globe with the `.routes(...)` modifier and `ImmersiveMapRoutesController`, fly a 3D model along the same trajectory with `ImmersiveMapSceneModelsController.animate(id:along:duration:)`, and travel the camera with it through `ImmersiveMapCameraController.follow(path:duration:)`. A route is a ribbon lifted off the surface by an altitude profile, so a flight path arcs away from the planet and back. It renders inside the map world pass: the far half of an arc disappears behind the globe because the shader tests every point against the sphere itself, and a model in front of the line covers it through the depth buffer. Line width is specified in points and stays constant on screen at any zoom.

```swift
struct MapScreen: View {
    @State private var routes = ImmersiveMapRoutesController()
    @State private var sceneModels = ImmersiveMapSceneModelsController()
    @State private var camera = ImmersiveMapCameraController()

    private let flight = ImmersiveMapGeoPath(
        from: GeoCoordinate(latitude: 55.7558, longitude: 37.6173),
        to: GeoCoordinate(latitude: 37.7749, longitude: -122.4194),
        peakAltitudeMeters: 400_000)

    var body: some View {
        ImmersiveMapView()
            .camera(camera)
            .routes(routes)
            .sceneModels(sceneModels)
            .onAppear {
                routes.add(ImmersiveMapRoute(id: 1,
                                             path: flight,
                                             color: SIMD4<Float>(1, 0.35, 0.25, 1),
                                             widthPoints: 2,
                                             progress: 0))
                routes.setProgress(id: 1, 1, duration: 4)

                guard let source = ImmersiveMapSceneModel.Source(resource: "plane",
                                                                 withExtension: "usdz") else { return }
                sceneModels.add(ImmersiveMapSceneModel(id: 1,
                                                       source: source,
                                                       coordinate: flight.waypoints[0],
                                                       fitDiameterMeters: 400_000))
                sceneModels.animate(id: 1, along: flight, duration: 12) { finished in
                    if finished { print("arrived") }
                }
                camera.follow(path: flight, duration: 12)
            }
    }
}
```

## Path

```swift
public struct ImmersiveMapGeoPath: Equatable, Hashable, Sendable {
    public var waypoints: [GeoCoordinate]
    public var baseAltitudeMeters: Double
    public var peakAltitudeMeters: Double

    public init(waypoints:baseAltitudeMeters:peakAltitudeMeters:)
    public init(from:to:baseAltitudeMeters:peakAltitudeMeters:)
    public func altitudeMeters(atFraction: Double) -> Double
}
```

| Parameter | Meaning |
|---|---|
| `waypoints` | Two or more coordinates joined by great-circle arcs, the shortest path over the sphere. Consecutive duplicates are ignored; a path with fewer than two distinct points draws nothing and animates nothing. |
| `baseAltitudeMeters` | Altitude held over the whole path, in meters above the map surface. |
| `peakAltitudeMeters` | Extra altitude at the middle of the path. The profile is `base + peak * sin(pi * fraction)`: it starts and ends at `base` and crests at `base + peak`. |

The path is parameterized by `fraction` in `0...1` measured along **arc length**, not by waypoint index: on a three-waypoint path whose segments span 2:1 of the total angle, the middle waypoint sits at `fraction` 2/3. The same parameterization drives the ribbon and the animated model, so the model rides exactly on the drawn line.

`peakAltitudeMeters` is in real meters, so pick it against the Earth's 6371 km radius: 400 km is a visible arc on a globe view, 10 km (a real cruising altitude) is invisible at that scale.

## Route

```swift
public struct ImmersiveMapRoute: Identifiable, Equatable, Sendable {
    public var id: UInt64                // assigned by the app
    public var path: ImmersiveMapGeoPath
    public var color: SIMD4<Float>       // straight (non-premultiplied) RGBA
    public var widthPoints: Double
    public var progress: Double          // 0...1, drawn from the start of the path
    public var dash: ImmersiveMapRouteDash?   // nil draws a solid line
}

public struct ImmersiveMapRouteDash: Equatable, Sendable {
    public var dashPoints: Double
    public var gapPoints: Double
}
```

`progress` truncates the ribbon at an exact arc-length fraction, so `0.5` ends the line precisely halfway along the path rather than at the nearest tessellated point. Sub-point widths stay visible: the line keeps a one-pixel body and pays for the missing width in alpha, so a thin route never flickers in and out while zooming.

A dash pattern is measured **along the route as it appears on screen**, not along the geometry, so dashes keep their size while zooming instead of stretching with the world; the engine projects the centerline every frame to get that length. A pattern with a zero dash or a zero gap is a solid line, so animating a dash to nothing degrades cleanly rather than shimmering.

## Controller

```swift
public final class ImmersiveMapRoutesController: @unchecked Sendable {
    public func set(_ routes: [ImmersiveMapRoute])   // full replace
    public func add(_ route: ImmersiveMapRoute)
    public func upsert(_ routes: [ImmersiveMapRoute])
    public func setProgress(id: UInt64, _ progress: Double, duration: TimeInterval = 0)
    public func remove(id: UInt64) / remove(ids:) / clear()
}
```

The controller is thread-safe and can be mutated from any thread. Rendering stays on-demand: an idle map with idle routes costs nothing. `setProgress` with a positive `duration` eases the change over that many seconds, which is the "line draws itself" effect; with the default `duration: 0` it snaps.

## Travelling the camera along a path

```swift
public func follow(path: ImmersiveMapGeoPath,
                   duration: TimeInterval,
                   curve: ImmersiveMapPathAnimationCurve = .easeOut,
                   options: ImmersiveMapCameraFollowOptions = .default,
                   completion: ((Bool) -> Void)? = nil)

public func cancelFollow()

public struct ImmersiveMapCameraFollowOptions: Equatable, Sendable {
    public enum Bearing: Equatable, Sendable { case course, unchanged, fixed(Float) }
    public var zoom: Double?          // nil keeps the camera's current zoom
    public var pitch: Float?          // nil keeps the camera's current pitch
    public var bearing: Bearing       // default .course
    public var smoothingHalfLife: Double   // default 0.35 s, 0 pins the camera
}
```

The camera resolves its own point of the path from the same metrics and curve a model animation uses, so a model and the camera started with the same `duration` and `curve` travel in step without anything passing between them. There is no separate "follow this model" mode; the path is the shared reference.

By default the camera keeps its zoom and pitch, so the app can keep zooming while the camera travels, and turns to the course, which puts the direction of travel up the screen. Note that on a zoomed-out globe the engine limits how far the camera may rotate (`CameraSettings.globeBearingUnlockZoom`, unlocked by zoom 6 with the default settings), so the turn is clamped there; the follow absorbs the clamp rather than fighting it, and the camera simply rotates as far as it is allowed.

`smoothingHalfLife` makes the camera trail the point and close half the remaining gap every half-life, which is what keeps a curved path from feeling rigid. The camera therefore ends the traversal slightly behind the destination rather than snapping onto it; pass `smoothingHalfLife: 0` when the endpoint has to be exact.

`completion` fires exactly once: `true` when the traversal ran out, `false` when another camera command superseded it (a `fly`, a `jump`, another `follow`), it was cancelled, or the user took the camera with a gesture. Anything the user does to the camera wins, exactly as it does over a flight.

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

`animate` moves an existing scene model along the path over `duration` seconds. With `appliesHeading` the model turns to face along the trajectory (course clockwise from north); with `appliesPitch` it tilts nose up while the altitude profile climbs and nose down while it descends. `curve` is `.easeOut` (leaves at full speed and settles onto the destination) or `.linear` (constant ground speed).

`completion` fires exactly once on the main thread: `true` when the model reached the end of the path, `false` when the animation was superseded by another `animate` for the same id, cancelled, or dropped because the model was removed, the map view went away, or the renderer was recreated by a settings change. That makes it safe to chain legs of a journey without leaking a waiting continuation.

While the animation runs the path owns the model's coordinate, altitude and, when the flags are set, heading and pitch: `move`, `setAltitude` and `setOrientation` for that id are ignored for as long as it runs, and do not resurface when it ends. Everything else, `setScale` included, still applies. `cancelPathAnimation(id:)` leaves the model where the flight got to, and the engine writes that position back into the descriptor, so a later mutation starts from where the model actually is. Note that this API is not limited to the globe: the model animation works in flat presentation and through the morph, only the drawn ribbon is globe-only.

## Limitations

- **Globe presentation only**: routes are drawn while the map is a globe, including the whole sphere-to-plane morph, and fade out over the last tenth of that morph. On the fully flat map nothing is drawn. The model animation is unaffected.
- **Style**: no gradient along the path, and butt end caps.
- **Camera course**: `Bearing.course` is subject to the engine's own globe bearing limit, so on a zoomed-out globe the camera turns only as far as `CameraSettings.globeBearingUnlockZoom` allows. Raise that setting, or zoom in, for a full chase.
- **Camera trailing**: with the default smoothing the camera ends a traversal slightly behind the destination rather than snapping onto it. Pass `smoothingHalfLife: 0` when the endpoint has to be exact.
- **Video export**: routes are not included in tour video exports, matching scene models.
- **Ground-level routes**: a route with a zero altitude profile lies exactly on the surface and can stipple against it under the depth test. Give a ground track a small `baseAltitudeMeters` (a few kilometers reads as flat at globe zoom). The altitude also moves the point's own horizon, so a lifted track legitimately stays visible slightly further around the planet than a ground one.
- **Ribbon width at the limb**: the ribbon is widened in screen space around a centerline that is hidden at the horizon, so where a route runs out over the limb its last half width can reach a couple of pixels past the silhouette.
- **Selection**: routes are not tappable.
