# JustGetIt

A modern multi-connection download manager for macOS 26 on Apple Silicon. Built
with SwiftUI and Liquid Glass, Swift 6 strict concurrency, and SwiftData.

[![Build DMG](https://github.com/cheginit/JustGetIt/actions/workflows/build.yml/badge.svg)](https://github.com/cheginit/JustGetIt/actions/workflows/build.yml)

## Features

- **Multi-connection downloads.** Files are split into byte-range chunks fetched over
  many parallel connections (HTTP Range requests) and written to per-offset file
  handles in a single pre-allocated file.
- **Work-stealing.** The file is divided into more chunks than connections, so when a
  fast connection finishes it pulls the next pending chunk and no connection sits idle.
- **Resume.** Per-chunk offsets are checkpointed to SwiftData, and paused or
  interrupted downloads continue with a Range request plus If-Range validation, so a
  changed file restarts cleanly.
- **Concurrent queue.** A configurable limit controls how many downloads run at once,
  and the rest wait their turn.
- **Transient error handling.** Server responses such as 429 and 503 are retried with
  jittered exponential backoff, honoring Retry-After.
- **Global hotkey.** A configurable, system-wide shortcut (default Cmd+Opt+Shift+D)
  starts downloading every URL on the clipboard.
- **Disk safety.** A missing folder is created, a full disk is caught up front when the
  size is known, and out-of-space writes fail cleanly.
- **Liquid Glass UI.** A sortable table, color-coded status, file-type icons, a floating
  glass stats bar, and a menu-bar popover with live progress.
- **Notifications** on completion and failure.

## Requirements

- macOS 26 or later on Apple Silicon
- Xcode 26 or later
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [create-dmg](https://github.com/create-dmg/create-dmg) for packaging (`brew install create-dmg`)

## Build and run

```bash
xcodegen generate      # regenerate JustGetIt.xcodeproj from project.yml
open JustGetIt.xcodeproj
# press Cmd+R in Xcode, then Cmd+N to add a download URL
```

## Package a DMG

```bash
./make-dmg.sh
```

This builds a Release, ad-hoc signed app and packages it as `JustGetIt.dmg`. Ad-hoc
signing runs locally without a Developer ID or notarization, so on first launch you
right-click the app and choose Open once to clear Gatekeeper.

Every push to `main` and every published release also builds the DMG in CI (see
[.github/workflows/build.yml](.github/workflows/build.yml)). Release builds attach the
DMG to the release.

## Architecture

```
DownloadEngine (actor)          owns the URLSession, the connection budget, and every
  ConnectionGate (actor)        active coordinator. Publishes an AsyncStream of events
  RemoteProbe                   the UI consumes.
  SegmentDataDelegate           URLSession delegate feeding per-task AsyncThrowingStreams.
  DownloadCoordinator (actor)   a worker pool pulls chunks from a pending queue
                                (work-stealing), retries stalls, and writes each chunk
                                to its offset in the .download file.

AppModel (MainActor, Observable)  bridges engine events to rows, persists records
                                  (SwiftData), runs the concurrency queue, and notifies.
```

## Engine smoke tests

`.smoketest/SmokeTest.swift` exercises the engine headlessly and verifies the
reassembled file against a known SHA-256. `.smoketest/FlakyServer.swift` is a small
localhost server used by the retry test, which confirms the engine retries transient
503 responses (honoring Retry-After) and still reassembles the file byte for byte.

```bash
SDK=$(xcrun --sdk macosx --show-sdk-path)
swiftc -sdk "$SDK" -target arm64-apple-macos26.0 \
  Sources/Models/Models.swift Sources/Engine/*.swift \
  .smoketest/SmokeTest.swift .smoketest/FlakyServer.swift \
  -o .smoketest/enginetest
./.smoketest/enginetest [connections] [url] [expectedSHA256]
./.smoketest/enginetest retry
```

## License

MIT. See [LICENSE](LICENSE).
