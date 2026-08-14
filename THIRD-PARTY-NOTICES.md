# Third-Party Notices

ImmersiveMap is licensed under the MIT license (see [LICENSE](LICENSE)). The
components below carry their own notices, reproduced here so that they are easy
to include in an app's acknowledgements screen.

## earcut (Mapbox)

`ImmersiveMap/Tile/Parse/Earcut.swift` is a Swift port of
[mapbox/earcut](https://github.com/mapbox/earcut), used under the ISC license:

```text
ISC License

Copyright (c) 2016, Mapbox

Permission to use, copy, modify, and/or distribute this software for any purpose
with or without fee is hereby granted, provided that the above copyright notice
and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
THIS SOFTWARE.
```

## swift-protobuf (Apple)

[apple/swift-protobuf](https://github.com/apple/swift-protobuf) is not vendored:
it is resolved by Swift Package Manager as a regular dependency and ships under
its own [Apache 2.0 license](https://github.com/apple/swift-protobuf/blob/main/LICENSE.txt),
which travels with that package.
