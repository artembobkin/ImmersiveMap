# Configuration

`Configuration` owns public map settings and the small planning layer that
decides how setting changes should be applied.

Settings are public API. This folder should describe configuration intent, not
perform runtime side effects directly.

## Responsibilities

- Define public settings accepted by ImmersiveMap.
- Classify setting changes into application domains.
- Produce setting application plans for runtime controllers.
- Keep configuration values provider-neutral and public-safe.

## May Contain

- Public settings value types.
- Public enums describing setting domains and apply actions.
- Pure comparison and planning helpers for settings transitions.
- Defaults that are safe to publish in the package.

## Must Not Contain

- Runtime controllers that directly mutate render, tile, camera, or UI state.
- Network clients, URL session code, bearer tokens, provider access tokens, or local
  development secrets.
- Metal resources, render graph code, shaders, or frame timing.
- Tile parsing, label decisions, avatar state, or host-app launch logic.
- Generated files or generated secret/config artifacts.
