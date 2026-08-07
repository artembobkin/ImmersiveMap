# Travelling the camera along a path

`ImmersiveMapCameraController.follow(path:duration:)` walks the camera along an `ImmersiveMapGeoPath` over a real duration, turning to the course as it goes. It is the camera half of a journey whose other halves are a [drawn route](routes.md) and a [flying model](scene-models.md): all three resolve their own point of the same path from the same metrics and curve, so starting them with the same `duration` and `curve` keeps them in step without anything passing between them at runtime.

```swift
struct MapScreen: View {
    @State private var camera = ImmersiveMapCameraController()

    private let flight = ImmersiveMapGeoPath(
        from: GeoCoordinate(latitude: 55.7558, longitude: 37.6173),
        to: GeoCoordinate(latitude: 37.7749, longitude: -122.4194),
        peakAltitudeMeters: 400_000)

    var body: some View {
        ImmersiveMapView()
            .camera(camera)
            .onAppear {
                camera.follow(path: flight, duration: 12) { finished in
                    if finished { print("arrived") }
                }
            }
    }
}
```

## API

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

| Field | Meaning |
|---|---|
| `zoom` / `pitch` | `nil` leaves the value alone, so the app (or the user) can keep zooming and tilting while the camera travels. A value takes over for the whole traversal. |
| `bearing` | `.course` puts the direction of travel up the screen, `.unchanged` keeps the current bearing, `.fixed` pins one. |
| `smoothingHalfLife` | How hard the camera trails its target point, in seconds to close half the remaining gap. `0` pins the camera exactly onto the path. |

`curve` is `.easeOut` (leaves at full speed and settles onto the destination) or `.linear` (constant ground speed). It is the same curve type a model animation takes, which is what makes the two agree.

## Behavior

`smoothingHalfLife` makes the camera trail the point and close half the remaining gap every half-life, which is what keeps a curved path from feeling rigid. The camera therefore ends the traversal slightly behind the destination rather than snapping onto it; pass `smoothingHalfLife: 0` when the endpoint has to be exact.

On a zoomed-out globe the engine limits how far the camera may rotate (`CameraSettings.globeBearingUnlockZoom`, unlocked by zoom 6 with the default settings), so `.course` is clamped there. The follow absorbs the clamp rather than fighting it: the camera simply turns as far as it is allowed.

`completion` fires exactly once: `true` when the traversal ran out, `false` when another camera command superseded it (a `fly`, a `jump`, another `follow`), it was cancelled, or the user took the camera with a gesture. Anything the user does to the camera wins, exactly as it does over a [flight](camera.md).

There is no separate "follow this model" mode. The path is the shared reference, so a leg of a journey is three calls with one duration:

```swift
routes.setProgress(id: legID, 1, duration: leg.seconds)
camera.follow(path: leg.path, duration: leg.seconds, options: followOptions)
sceneModels.animate(id: planeID, along: leg.path, duration: leg.seconds) { finished in
    guard finished else { return }   // false means superseded or cancelled
    flyLeg(index: index + 1)
}
```

## Limitations

- **Camera course**: `Bearing.course` is subject to the engine's own globe bearing limit, so on a zoomed-out globe the camera turns only as far as `CameraSettings.globeBearingUnlockZoom` allows. Raise that setting, or zoom in, for a full chase.
- **Camera trailing**: with the default smoothing the camera ends a traversal slightly behind the destination. Pass `smoothingHalfLife: 0` when the endpoint has to be exact.
- Unlike the drawn route, following works in both presentations: the path is geometry, not a globe-only ribbon.

Running example: [`Examples/ImmersiveMapRoutesMac`](../../Examples/ImmersiveMapRoutesMac) flies a round-the-world journey leg by leg with the camera travelling along each one.
