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

## Configuration

Build-time settings live in `Config.example.xcconfig` (committed, safe defaults) and flow through `project.yml` → `Info.plist` → app code. To override a value locally without touching git-tracked files, copy `Config.example.xcconfig` to `Config.local.xcconfig` (gitignored) and edit it there — it's included automatically by `Config.example.xcconfig` and takes precedence. Run `make generate` after changing either file to regenerate the Xcode project.

xcconfig treats `//` as a comment delimiter anywhere on a line, so any URL value (in either `Config.example.xcconfig` or `Config.local.xcconfig`) must escape it with `$()`, e.g. `http:/$()/localhost:8080` — otherwise the value is silently truncated to `http:`.

| Setting | Where it lives | Default | Description |
|---|---|---|---|
| `RIZE_BACKEND_BASE_URL` | `Config.example.xcconfig` / `Config.local.xcconfig` → Info.plist key `RIZE_BACKEND_BASE_URL` | `http://localhost:8080/v1` | Base URL of the sync/auth API (RIZ-41), read at runtime by `UserDefaultsBaseURLProvider.baseURL()`. |
| `apiBaseURL` | `UserDefaults` (standard suite) | unset (falls through to the Info.plist value above) | Runtime override of the backend base URL for QA/staging without a rebuild. Takes priority over the Info.plist/xcconfig value; see `UserDefaultsBaseURLProvider`. |

Coverage thresholds and other CI-only knobs (e.g. `COVERAGE_THRESHOLD` in the `Makefile`) are not app runtime configuration and stay in `Makefile`/CI workflow files.

## Release (`.github/workflows/release.yml`)

Pushing a `v*` tag builds and attaches a release artifact:

- **Backend base URL**: set the `BACKEND_BASE_URL` GitHub *repository variable* (Settings → Secrets and variables → Actions → Variables) to the URL the released app should point at. The workflow writes it into a generated `Config.local.xcconfig` before `xcodegen generate`, so it flows through the same `RIZE_BACKEND_BASE_URL` seam described above. If unset, the build falls back to `Config.example.xcconfig`'s committed `http://localhost:8080` default.
- **Signing**: if all five secrets `MACOS_CERT_P12_BASE64` (base64-encoded Developer ID Application .p12), `MACOS_CERT_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_ID`, and `APPLE_APP_SPECIFIC_PASSWORD` (an [app-specific password](https://support.apple.com/en-us/102654) for `notarytool`) are configured as repo secrets, the workflow builds a Developer ID-signed, hardened-runtime, notarized-and-stapled `RizeDesktop-signed.zip`. If any is missing, it falls back to an unsigned `RizeDesktop-unsigned.zip` (Gatekeeper will warn on install). No App Sandbox entitlements are applied in either path, per this app's distribution model.

## Documentation

- [Desktop architecture](../documentation/architecture-desktop.md)
- [Sync protocol](../documentation/sync-protocol.md)
- [API reference](../documentation/api-reference.md)
- [Security requirements](../documentation/security.md)

## Git flow

One Linear ticket (`RIZ-<n>`) → one branch `feat/RIZ-<n>-<slug>` (or `fix/`, `docs/`, `chore/`) → one PR titled `[RIZ-<n>] <summary>` into `main`, linking the ticket. Conventional Commits referencing `RIZ-<n>`.
