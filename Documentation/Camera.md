# Camera

The camera looks at a point of the map from a zoom, turned by a bearing and tilted by a pitch. Angles are in radians: the bearing clockwise from north, the pitch from straight down.

## Gestures

Out of the box, a user can:

- **Pan.** Drag with one finger, or with the mouse.
- **Zoom.** Pinch, or scroll with the trackpad or the mouse wheel.
- **Rotate.** Twist with two fingers.
- **Tilt.** Drag two fingers up or down. On a Mac, drag with the right button or with Option held.

On iPhone and iPad, the bottom corners hold invisible one-thumb drag zones: the leading corner tilts and the trailing one zooms. Turn them off where your own controls sit:

```swift
ImmersiveMapView()
    .cameraControlZones(pitch: false, zoom: false)
```

The speed and the direction of a tilt drag are set with `.tiltGestureSensitivity(_:)`.

## The starting position

```swift
ImmersiveMapView()
    .cameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: 48.8584,
                                               longitudeDegrees: 2.2945,
                                               zoom: 16,
                                               bearing: 0,
                                               pitch: 1.0))
```

### Cities

For a well-known city, `ImmersiveMapCity` holds the coordinates, so the app keeps none:

```swift
ImmersiveMapView()
    .cameraPosition(.city(.paris))
```

The camera stands over the city's centre at zoom 11, where the city shows whole, looking straight down with north up. Set the rest when you need it:

```swift
.cameraPosition(.city(.tokyo, zoom: 13, bearing: 0.5, pitch: 1.0))
```

The same value works wherever a camera position does, such as `camera.fly(to: .city(.sydney))` or a tour's shot. `ImmersiveMapCity.allCases` lists the cities for a picker, each with its English `name` and its `coordinate`.

The cities:

- **North America:** `newYork`, `losAngeles`, `sanFrancisco`, `chicago`, `washington`, `boston`, `miami`, `seattle`, `lasVegas`, `toronto`, `vancouver`, `montreal`, `mexicoCity`.
- **South America:** `rioDeJaneiro`, `saoPaulo`, `buenosAires`, `lima`, `bogota`, `santiago`.
- **Europe:** `london`, `paris`, `berlin`, `madrid`, `barcelona`, `rome`, `milan`, `amsterdam`, `vienna`, `prague`, `lisbon`, `athens`, `stockholm`, `copenhagen`, `oslo`, `helsinki`, `dublin`, `brussels`, `zurich`, `munich`, `warsaw`, `budapest`, `istanbul`, `moscow`, `saintPetersburg`, `kyiv`.
- **Africa and the Middle East:** `dubai`, `telAviv`, `cairo`, `capeTown`, `johannesburg`, `nairobi`, `lagos`, `marrakesh`.
- **Asia:** `tokyo`, `osaka`, `seoul`, `beijing`, `shanghai`, `hongKong`, `taipei`, `singapore`, `bangkok`, `kualaLumpur`, `jakarta`, `manila`, `hanoi`, `mumbai`, `delhi`.
- **Oceania:** `sydney`, `melbourne`, `auckland`.

A place that is not in the list takes an `ImmersiveMapCameraPosition` with its own coordinates, as above.

## Moving the camera from code

Keep an `ImmersiveMapCameraController` and attach it to the map:

```swift
@State private var camera = ImmersiveMapCameraController()

var body: some View {
    ImmersiveMapView()
        .cameraController(camera)
}
```

Then:

- **Jump.** `camera.jump(to: position)` moves the camera at once.
- **Fly.** `camera.fly(to: position)` animates there, 1.35 seconds by default. For a long trip, rise over the map first and dive at the target:
  ```swift
  camera.fly(to: position,
             options: CameraFlightOptions(duration: 4, altitudeStyle: .overviewFirst)) { finished in
      // false when a gesture or another command interrupted it
  }
  ```
- **Follow a path.** `camera.follow(path:duration:)` carries the camera along an `ImmersiveMapGeoPath`, turned to the direction of travel by default:
  ```swift
  camera.follow(path: path, duration: 20, curve: .linear)
  ```
  `curve` sets the pace. `.easeOut`, the default, leaves at full speed and settles onto the end, and `.linear` keeps one speed. A model can fly the same path with the camera on it (see [3D content](3DContent.md)).
- **Stop.** `camera.cancelFlight()` and `camera.cancelFollow()`.

The controller also tells you where the camera is: `currentCameraPosition()`, and `onCameraPositionChanged` as it moves. `onUserInteractionBegan` reports that the user took the camera.

## Tours

`ImmersiveMapCameraTourController` flies through a list of shots, holding at each one. It stops when the user touches the map:

```swift
let tour = ImmersiveMapCameraTourController(camera: camera)
tour.start(shots: [
    ImmersiveMapCameraTourShot(position: eiffelTower, holdAfter: 2),
    ImmersiveMapCameraTourShot(position: louvre, options: CameraFlightOptions(duration: 3)),
], loop: true)
```

The tour flies to the first shot from wherever the camera is. Pass `establish:` to jump to a starting position first. The same shots can be recorded into a video (see [Export](Export.md)).

## On-screen buttons

`.enableCameraUIControls()` shows buttons for the bearing and the pitch. They work with or without a controller.

## Limits

Gestures, commands and flights all keep within these:

```swift
ImmersiveMapView()
    .zoomRange(minimum: 3, maximum: 18)
    .pitchRange(minimum: 0, maximum: 1.2)
    .bearingLimit(.pi / 2)  // at most a quarter turn from north
```

A zoomed-out globe turns back to north-up and straight-down on its own. Tune that with `.globeUprightPull(zoomRange:halfLife:)`, or turn it off with `.globeUprightPull(nil)`.

## Bounds

For a map of one city or one country, keep the camera over it:

```swift
ImmersiveMapView()
    .cameraBounds(southWest: GeoCoordinate(latitude: 55.57, longitude: 37.36),
                  northEast: GeoCoordinate(latitude: 55.92, longitude: 37.86))
```

The zoomed-out globe still turns freely. As the camera zooms in, the area it may look at closes in on the region, between zooms 1 and 2 by default, and from there on the camera stays over the region. A flight never lands outside it.

- `pullZoomRange` sets the zooms over which the area closes in. With `3...3`, the world is open up to zoom 3 and the region alone past it.
- `pullCurve` sets how it closes across those zooms: `.linear`, `.easeIn`, `.easeOut`, `.easeInOut` (the default), or your own `PullCurve(x1:y1:x2:y2:)`, as in CSS `cubic-bezier()`.
- `edgeBehavior` sets what happens at the edge:
  - `.elastic()`, the default: the camera can be dragged past the edge, up to about 200 points, and is pulled back, harder the farther out it is. Tune it with `.elastic(maximumStretch:pullHalfLife:pullProgression:)`.
  - `.hard`: the edge is a wall for gestures, commands and flights.

A region across the antimeridian has a west longitude greater than its east one. `.cameraBounds(nil)` opens the whole world again.
