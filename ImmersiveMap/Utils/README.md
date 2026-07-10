# Utils

`Utils` contains small shared utilities that do not justify ownership by a more
specific engine folder.

This folder should remain narrow. Prefer placing code in the domain folder that
owns the behavior whenever there is a clear owner.

## Responsibilities

- Provide small cross-cutting helpers.
- Keep reusable math and main-thread helpers out of unrelated feature folders.
- Avoid duplicating utility logic across subsystems.

## May Contain

- Small deterministic math helpers used by multiple subsystems.
- Main-thread assertion or dispatch helpers.
- Platform graphics shims shared by UIKit and AppKit code paths
  (`PlatformGraphics`: color/font/bezier typealiases and CGImage rasterization).
- Tiny stateless helpers with no better domain-specific owner.

## Must Not Contain

- Large subsystems, runtime controllers, renderers, parsers, or caches.
- Public API that belongs to a domain folder such as `UI`, `Camera`, or
  `Configuration`.
- Metal resources, tile networking, vector tile provider adaptation, or label
  runtime state.
- Host-app code, secrets, private endpoints, or machine-specific configuration.
- Convenience code that only has one caller and belongs next to that caller.
