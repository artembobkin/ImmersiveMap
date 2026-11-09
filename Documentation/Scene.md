# The scene

Beyond the map's own colours (see [Style](Style.md)), the scene around it has a look of its own: the globe and space, the sun and the shadows, the sky and the fog, the buildings and the trees. Everything here is on by default, and each modifier sets only the values you pass, leaving the others as they are.

## Globe and space

```swift
ImmersiveMapView()
    .globe(isEnabled: false)       // a flat map at every zoom
    .atmosphere(isEnabled: false)  // no glow around the globe
    .transparentSpace()            // your own background around the globe
```

The zoomed-out map is a globe in space, which unrolls into the flat map as you zoom in. `.transparentSpace()` draws no space and no stars, so whatever is behind the map shows around the planet.

The globe is lit by a sun, with a night side. `.globeLight(subsolarLatitudeDegrees:subsolarLongitudeDegrees:strength:nightColor:)` moves the sun and tunes the night, and `.globeLight(isEnabled: false)` lights the globe evenly.

## Sun and shadows

On the flat map, buildings, trees and models cast shadows from a fixed sun:

```swift
ImmersiveMapView()
    .sceneLight(direction: SIMD3(-0.5, -0.4, 0.8))  // towards the sun: x east, y north, z up
    .shadows(strength: 0.6, softness: 1.5)
```

`.shadows(isEnabled: false)` turns them off. The shadows' other values, such as how far from the camera they reach, are on the same modifier.

## Sky and fog

The flat map has a sky above its horizon, and a fog that rises from the ground and veils the far distance:

```swift
ImmersiveMapView()
    .fog(isEnabled: false)        // no sky gradient
    .groundFog(isEnabled: false)  // no ground fog
```

The ground fog is tuned with `.groundFog(densityPerKilometer:heightMeters:startDistanceMeters:...)`. Most of its values are curves over the zoom, written as `[12: 3000, 16: 400]`, so the fog changes smoothly as you zoom. With the relief on, `.mountainGroundFog(...)` gives the mountains an air of their own (see [Relief](Relief.md)).

## Buildings and trees

```swift
ImmersiveMapView()
    .buildingExtrusion(buildingsMinimumZoom: 15, risesFromTheGround: false)
    .trees(minimumZoom: 15, maximumPerTile: 2000)
```

- **Buildings** stand up from zoom 14 by default, growing out of the ground in 0.6 seconds when they appear. `risesFromTheGround: false` shows them at once.
- **Trees** stand on woods and parks from zoom 14. `.trees(isEnabled: false)` removes them, and `maximumPerTile` limits how many draw, for a lighter frame.

## Smoother edges

The map's lines are smooth already. For smoother building and model edges, at some cost in speed:

```swift
ImmersiveMapView()
    .msaa()   // 4 samples a pixel, the cleaner of the two
    .fxaa()   // one cheap pass over the finished frame
```
