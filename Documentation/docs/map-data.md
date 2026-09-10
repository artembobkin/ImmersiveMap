# Where the Map Data Comes From

[immersivemap.dev](https://immersivemap.dev) is the tile service run for this project, and the source the engine renders by default. It serves a planet build assembled from [OpenStreetMap](https://www.openstreetmap.org/copyright) data, under ODbL, as vector tiles.

Nothing is required to start: `ImmersiveMapView()` renders against the service anonymously, on a shared public pool, with no token, no account and no sign-up. The demo apps in this repository do exactly that.
