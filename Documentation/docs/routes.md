# Routes

Draw great-circle routes over the globe with the `.routes(...)` modifier and `ImmersiveMapRoutesController`, and fly a 3D model along the same trajectory with `ImmersiveMapSceneModelsController.animate(id:along:duration:)`. A route is a ribbon lifted off the surface by an altitude profile, so a flight path arcs away from the planet and back; it renders inside the map world pass with real depth, which is what makes the far half of the arc disappear behind the globe and a model in front of the line cover it. Line width is specified in points and stays constant on screen at any zoom.

```swift
struct MapScreen: View {
    @State private var routes = ImmersiveMapRoutesController()
    @State private var sceneModels = ImmersiveMapSceneModelsController()

    private let flight = ImmersiveMapGeoPath(
        from: GeoCoordinate(latitude: 55.7558, longitude: 37.6173),
        to: GeoCoordinate(latitude: 37.7749, longitude: -122.4194),
        peakAltitudeMeters: 400_000)

    var body: some View {
        ImmersiveMapView()
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
}
```

`progress` truncates the ribbon at an exact arc-length fraction, so `0.5` ends the line precisely halfway along the path rather than at the nearest tessellated point. Sub-point widths stay visible: the line keeps a one-pixel body and pays for the missing width in alpha, so a thin route never flickers in and out while zooming.

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

While the animation runs the path owns the model's coordinate, altitude and, when the flags are set, heading and pitch. `move`, `setAltitude` and `setOrientation` for that id are recorded on the descriptor but not applied until the animation ends or is cancelled; `setScale` still applies. Cancel first if the app needs to take over mid-flight. Note that this API is not limited to the globe: the model animation works in flat presentation and through the morph, only the drawn ribbon is globe-only.

## Limitations

- **Globe presentation only**: routes are drawn while the map is a globe, including the whole sphere-to-plane morph, and fade out over the last tenth of that morph. On the fully flat map nothing is drawn. The model animation is unaffected.
- **Style**: solid lines only in this version, no dash pattern, no gradient along the path, and butt end caps.
- **Video export**: routes are not included in tour video exports, matching scene models.
- **Ground-level routes**: a route with a zero altitude profile lies exactly on the surface and can stipple against it under the depth test. Give a ground track a small `baseAltitudeMeters` (a few kilometers reads as flat at globe zoom).
- **Selection**: routes are not tappable.
