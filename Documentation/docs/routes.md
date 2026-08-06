# Routes

Draw great-circle routes over the globe with the `.routes(...)` modifier and `ImmersiveMapRoutesController`. A route is a ribbon lifted off the surface by an altitude profile, so a flight path arcs away from the planet and back; it renders inside the map world pass with real depth, which is what makes the far half of the arc disappear behind the globe and a model in front of the line cover it. Line width is specified in points and stays constant on screen at any zoom.

A route is one of three things that can share a path. The other two have their own pages: [flying a model along it](scene-models.md) and [travelling the camera with it](camera-path-follow.md).

```swift
struct MapScreen: View {
    @State private var routes = ImmersiveMapRoutesController()

    private let flight = ImmersiveMapGeoPath(
        from: GeoCoordinate(latitude: 55.7558, longitude: 37.6173),
        to: GeoCoordinate(latitude: 37.7749, longitude: -122.4194),
        peakAltitudeMeters: 400_000)

    var body: some View {
        ImmersiveMapView()
            .routes(routes)
            .onAppear {
                routes.add(ImmersiveMapRoute(id: 1,
                                             path: flight,
                                             color: SIMD4<Float>(1, 0.35, 0.25, 1),
                                             widthPoints: 2,
                                             progress: 0))
                routes.setProgress(id: 1, 1, duration: 4)
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

The path is parameterized by `fraction` in `0...1` measured along **arc length**, not by waypoint index: on a three-waypoint path whose segments span 2:1 of the total angle, the middle waypoint sits at `fraction` 2/3. The same parameterization drives the ribbon, the animated model and the camera, so all three ride exactly the same line.

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

Two routes over one path is the idiomatic way to show a plan and the progress against it: a dashed, dim route at full `progress` underneath, and a solid, bright one that grows over it.

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

## Limitations

- **Globe presentation only**: routes are drawn while the map is a globe, including the whole sphere-to-plane morph, and fade out over the last tenth of that morph. On the fully flat map nothing is drawn. Model animation and camera follow over the same path are unaffected.
- **Style**: no gradient along the path, and butt end caps.
- **Video export**: routes are not included in [tour video exports](tour-video-export.md), matching scene models.
- **Ground-level routes**: a route with a zero altitude profile lies exactly on the surface and can stipple against it under the depth test. Give a ground track a small `baseAltitudeMeters` (a few kilometers reads as flat at globe zoom).
- **Selection**: routes are not tappable.

Running example: [`Examples/ImmersiveMapRoutesMac`](../../Examples/ImmersiveMapRoutesMac) draws a round-the-world journey leg by leg, with a dashed plan under a solid line that grows along it.
