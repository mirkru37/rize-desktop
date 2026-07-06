# rize-desktop

macOS menu-bar client. Stack: Swift 5.10+, SwiftUI + AppKit (NSStatusItem shell), GRDB/SQLite, macOS 14+ target.

## Rules

- **Consult `../documentation/` before changing any contract.** Sync payload types must mirror `api-reference.md` / `sync-protocol.md` exactly; the local event schema mirrors `database-schema.md`.
- Architecture: MVVM with `@Observable` models; async/await only (no Combine unless a framework forces it).
- The tracking engine (NSWorkspace/Accessibility/CGEventSource) is isolated from UI code — no AppKit/SwiftUI imports inside tracking components.
- Activity events are immutable once closed: client-generated UUIDv7, sessions under 5 s discarded, written to the SQLite outbox and marked synced only after server ack.
- Permissions: check `AXIsProcessTrusted`; degrade to app-name-only tracking when Screen Recording is denied. No App Sandbox — distribution is Developer ID + notarization with hardened runtime.
- Style: SwiftFormat + SwiftLint; tests with XCTest. New functionality must be covered before a PR opens.

## Git flow

One Linear ticket (`RIZ-<n>`) → one branch `feat/RIZ-<n>-<slug>` (or `fix/`, `docs/`, `chore/`) → one PR `[RIZ-<n>] <summary>` into `main`, linking the ticket. Conventional Commits referencing `RIZ-<n>`. Never open a PR with failing tests or lint.
