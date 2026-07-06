# rize-desktop

macOS menu-bar client for Rize-Clone: automatic time tracking via native APIs (frontmost app, window titles, idle detection), offline-first local store, batched sync to the backend. Part of the [Rize-Clone](../README.md) master repo.

## Stack

- **Swift 5.10+**, **SwiftUI** for UI, **AppKit** for the `NSStatusItem` menu-bar shell
- Tracking: `NSWorkspace` (frontmost app), Accessibility API / `CGWindowList` (window titles), `CGEventSource` (idle)
- **GRDB/SQLite** offline-first event store with an outbox for sync
- Target: **macOS 14+**; distribution via **Developer ID + notarization** (not the Mac App Store — the Accessibility API is incompatible with App Sandbox)

## Development permissions

Running a dev build requires granting in System Settings → Privacy & Security:

- **Accessibility** — focused-window titles (primary tracking path)
- **Screen Recording** — only if `CGWindowList` window titles are enabled; the app degrades gracefully to app-name-only tracking when denied

## Build

Open the Xcode project, or:

```
xcodebuild -scheme RizeDesktop build
xcodebuild -scheme RizeDesktop test
```

## Documentation

- [Desktop architecture](../documentation/architecture-desktop.md)
- [Sync protocol](../documentation/sync-protocol.md)
- [API reference](../documentation/api-reference.md)
- [Security requirements](../documentation/security.md)

## Git flow

One Linear ticket (`RIZ-<n>`) → one branch `feat/RIZ-<n>-<slug>` (or `fix/`, `docs/`, `chore/`) → one PR titled `[RIZ-<n>] <summary>` into `main`, linking the ticket. Conventional Commits referencing `RIZ-<n>`.
