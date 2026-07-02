# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-07-02

Initial beta release.

### Added

- Multi-connection downloads that split each file into byte-range chunks fetched over
  parallel connections, with work-stealing so no connection sits idle.
- Resume for paused or interrupted downloads, using per-chunk checkpoints and If-Range
  validation.
- A concurrency queue with a configurable limit on how many downloads run at once.
- Retry of transient server errors such as 429 and 503, with jittered exponential
  backoff that honors Retry-After.
- A configurable, system-wide hotkey that downloads every URL on the clipboard.
- An option to replace spaces in file names with dots.
- Disk safety checks for a missing folder, insufficient free space, and a full disk
  during a download.
- A right-click menu on downloads with open, reveal in Finder, copy URL, pause, resume,
  get info, remove, and move to trash.
- A Liquid Glass interface with a sortable table, color-coded status, file-type icons,
  a menu-bar popover, and completion notifications.

[Unreleased]: https://github.com/cheginit/JustGetIt/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/cheginit/JustGetIt/releases/tag/v0.1.0
