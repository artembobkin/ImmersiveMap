# StillCapture

`StillCapture` owns the public value types for rendering one frame of the map
offscreen into an image: the capture configuration and the error it can fail
with.

This is the still sibling of `VideoExport`. It is a separate folder because it
shares none of that one's machinery: there is no AVFoundation here, no encoder,
no timeline. The rendering side (offscreen targets, the scripted clock) lives in
`Render`; the public recorder and the capture loop live in `UI/Export`, next to
the video recorder they are built from.

## Responsibilities

- Define the public still capture configuration and error types.
- Validate the capture geometry before any GPU work is scheduled.

## May Contain

- Public value types describing capture options.
- Pure helpers for geometry validation.

## Must Not Contain

- Metal code, render graph code, textures, or GPU resource lifetime.
- AVFoundation, CoreVideo, or any encoder.
- UIKit/AppKit/SwiftUI views, controllers, or host-app lifecycle code.
- Camera, tile, label, or avatar state.
- Network clients or credentials.
