# Where the Map Data Comes From

[immersivemap.dev](https://immersivemap.dev) is the tile service run for this project, and the source the engine renders by default. It serves a planet build assembled from [OpenStreetMap](https://www.openstreetmap.org/copyright) data, under ODbL, as vector tiles.

Nothing is required to start: `ImmersiveMapView()` renders against the service anonymously, on a shared public pool, with no token, no account and no sign-up. The demo apps in this repository do exactly that.

A free key from [immersivemap.dev/account](https://immersivemap.dev/account) moves you off that shared pool onto your own throughput, and the account dashboard is where you create keys and watch your tile usage.

The site is also the home of the project: what the service covers, how it is built, and how to get in touch.
