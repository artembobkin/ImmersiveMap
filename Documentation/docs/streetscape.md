# The Streetscape

The streetscape is the measured street: the carriageway surfaces and the paint on them. It is optional and off by default.

```swift
ImmersiveMapView()
    .streetscape(isEnabled: true)
```

The surfaces are reconstructed from the road graph with [osm2streets](https://github.com/a-b-street/osm2streets).
