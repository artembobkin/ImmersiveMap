# ImmersiveMap.docc

`ImmersiveMap.docc` contains the DocC documentation catalog for the public
ImmersiveMap package.

This folder documents public package usage and concepts. It should not become a
dumping ground for internal design notes, private environment details, or
runtime assets.

## Responsibilities

- Provide DocC articles and public package documentation.
- Explain supported public API and user-facing concepts.
- Keep documentation safe for a public GitHub repository.

## May Contain

- DocC Markdown articles.
- Public API overviews and usage examples.
- Public-safe diagrams or resources required by DocC documentation.
- Generic configuration examples that do not include real credentials.

## Must Not Contain

- Bearer tokens, provider access tokens, private URLs, or local environment notes.
- Internal stand documentation, database credentials, or generated secret files.
- Build artifacts, screenshots from private sessions, or DerivedData.
- Hand-written Swift, Metal, Proto, or renderer implementation files.
- Host-app-specific instructions that are not relevant to the package docs.
