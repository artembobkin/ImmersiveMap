# Camera flights and scripted tours

`ImmersiveMapCameraController` is how an app drives the map: jump somewhere, fly there, read the current position, and hear about what the user did. `ImmersiveMapCameraTourController` chains flights into a scripted sequence. Attach the controller with `.camera(_:)`, optionally with the position the map should open at.

```swift
struct MapScreen: View {
    @State private var camera = ImmersiveMapCameraController()

    private let paris = ImmersiveMapCameraPosition(latitudeDegrees: 48.8566,
                                                   longitudeDegrees: 2.3522,
                                                   zoom: 13,
                                                   bearing: 0,
                                                   pitch: 0.4)

    var body: some View {
        ImmersiveMapView()
            .camera(camera, position: paris)
            .enableCameraUIControls()
            .onAppear {
                camera.onCameraPositionChanged = { position in
                    print("now at \(position.latitudeDegrees), \(position.longitudeDegrees)")
                }
            }
    }
}
```

## Position

```swift
public struct ImmersiveMapCameraPosition: Equatable, Sendable {
    public let latitudeDegrees: Double
    public let longitudeDegrees: Double
    public let zoom: Double
    public let bearing: Float      // radians, clockwise from north
    public let pitch: Float        // radians from straight down
}
```

`bearing` and `pitch` are in **radians**, unlike the degrees used by markers and scene models: the camera is the engine's own coordinate frame, not a geographic annotation. Pitch is clamped by `CameraSettings.maximumPitch` (and further by the zoom-dependent limits described below), so a position asking for more tilt than the current zoom allows is accepted and clamped rather than rejected.

## Moving the camera

```swift
public func jump(to position: ImmersiveMapCameraPosition)

public func fly(to position: ImmersiveMapCameraPosition,
                options: CameraFlightOptions = .default,
                completion: ((Bool) -> Void)? = nil)

public func cancelFlight()

public func currentCameraPosition() -> ImmersiveMapCameraPosition?
public func currentCameraSnapshot() -> ImmersiveMapCameraSnapshot?
```

`jump` is instant. `fly` animates, and its `completion` fires exactly once: `true` on arrival, `false` when the flight was superseded by another camera command, cancelled, or taken over by a user gesture.

```swift
public struct CameraFlightOptions: Sendable, Equatable {
    public let duration: TimeInterval          // default 1.35
    public let routeStyle: CameraFlightRouteStyle
    public let altitudeStyle: CameraFlightAltitudeStyle
}
```

| `routeStyle` | Ground track |
|---|---|
| `.automatic` | Picks between the two below from the distance. The default. |
| `.mercatorShortestPath` | A straight line in the flat projection. Right for short hops and for turning in place. |
| `.greatCircle` | The shortest path over the sphere, which is what makes an intercontinental flight visibly rotate the globe. |

| `altitudeStyle` | Zoom over time |
|---|---|
| `.direct` | Zoom interpolates straight from the start value to the target. |
| `.overviewFirst` | The cinematic van Wijk and Nuij arc: the camera gains altitude (the farther the target, the higher the apex, up to a globe view), covers most of the distance from above, and dives onto the target. |

`currentCameraSnapshot()` returns the position plus the limits in force at that moment (`ImmersiveMapCameraAngleLimits`, `ImmersiveMapCameraBearingLimits`), which is what a custom control panel needs to know how far its sliders may go.

To move the camera along a geographic path rather than to a point, see [travelling the camera along a path](camera-path-follow.md).

## Callbacks

```swift
public var onMapBackgroundTap: (() -> Void)?
public var onUserInteractionBegan: (() -> Void)?
public var onCameraPositionChanged: ((ImmersiveMapCameraPosition) -> Void)?
public var onCameraSnapshotChanged: ((ImmersiveMapCameraSnapshot) -> Void)?
```

`onUserInteractionBegan` fires when a gesture takes the camera over, which is the signal to abandon whatever the app was doing to it. `onCameraPositionChanged` and `onCameraSnapshotChanged` fire on the main thread as the camera moves, whatever moved it. Both fire per rendered frame during a gesture or flight, so keep the work in them small.

## Gestures and on-screen controls

```swift
func enableCameraUIControls(_ isEnabled: Bool = true, maximumPitch: Float = …) -> ImmersiveMapView
func zoomRange(minimum: Double? = nil, maximum: Double? = nil) -> ImmersiveMapView
func cameraControlZones(pitch: Bool = true, zoom: Bool = true) -> ImmersiveMapView
```

- `enableCameraUIControls` adds the built-in control panel (`ImmersiveMapCameraControlPanel`, itself public if you want to place it yourself).
- `zoomRange` clamps gestures, camera commands and flights alike. A minimum above the globe-to-flat transition window keeps the map flat for good, see [globe rendering](globe.md).
- `cameraControlZones` turns on the invisible one-thumb drag zones in the bottom corners (leading tilts, trailing zooms). Both are off by default because a zone captures drags that would otherwise pan the map and nothing on screen announces it. Touch platforms only; accepted and ignored on macOS.

Everything else about gesture feel lives on `ImmersiveMapSettings.CameraSettings` and is attached with `.cameraSettings(_:)`. The fields worth knowing:

| Field | Meaning |
|---|---|
| `maximumPitch` | Hard tilt ceiling, in radians. |
| `minimumZoom` / `maximumZoom` | What `zoomRange` writes. |
| `globeBearingUnlockZoom` / `globePitchUnlockZoom` | Below these zooms the globe limits how far the camera may rotate and tilt. This is also what clamps a `.course` path follow on a zoomed-out globe. |
| `highZoomPitchExtension…` / `extraHighZoomPitchExtension…` | Extra tilt earned back as the camera comes down to street level. |
| `globePanInertia…` | Whether and how a flick keeps the globe spinning. |
| `pinchZoomFactor`, `dragZoomFactor`, `worldPanSensitivity`, `rotationGestureSensitivity` | Gesture-to-motion ratios. |
| `pitchFollow…` / `bearingFollow…` | Half-lives for how the camera settles onto a commanded angle. |

## Scripted tours

```swift
public struct ImmersiveMapCameraTourShot: Sendable, Equatable {
    public let position: ImmersiveMapCameraPosition
    public let options: CameraFlightOptions
    public let holdAfter: TimeInterval
}

@MainActor
public final class ImmersiveMapCameraTourController {
    public init(camera: ImmersiveMapCameraController)
    public var isRunning: Bool
    public func start(shots: [ImmersiveMapCameraTourShot],
                      establish: ImmersiveMapCameraPosition? = nil,
                      loop: Bool = false,
                      stopOnUserInteraction: Bool = true,
                      onFinished: (() -> Void)? = nil)
    public func stop()
}
```

A tour is a list of shots played by chaining `fly` completions. `establish` jumps to a starting position first, so a looped tour has a seamless seam. `holdAfter` dwells on a shot after arrival. `stopOnUserInteraction` (on by default) kills the tour the moment a gesture begins, so flights never fight the user. `onFinished` is called exactly once for any ending: the last shot, `stop()`, or a user takeover.

`start` stops a running tour first, and a tour that is superseded cannot resurrect: the controller tracks generations so the tail of a cancelled sequence never finishes a newer one.

The same shot list can be rendered to a file instead of the screen, see [tour video export](tour-video-export.md).

## Limitations

- Angles are radians for the camera and degrees for map content; the two conventions do not meet, but they do sit next to each other in an app.
- Pitch and bearing limits are zoom-dependent on the globe. Commands are clamped rather than refused, so a flight to a heavily tilted globe position lands level and gains its tilt as it zooms in.
- The tour controller is `@MainActor`; the camera controller is not, but its callbacks are delivered on the main thread.

Running example: [`Examples/macOS/ImmersiveMapCameraTourMac`](../../Examples/macOS/ImmersiveMapCameraTourMac) plays a ten-shot cinematic that exercises every route and altitude style, and exports the same list to a video file.
