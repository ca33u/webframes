# Web Frames

A native macOS workspace for web projects and AI coding agents. Put live
pages, localhost routes and components on an infinite canvas, pin comments
with DOM context, and hand them to Codex or Claude Code for fixes you review
before anything is written.

Download the signed build at [webframes.pro](https://www.webframes.pro).

## Requirements

- Apple Silicon Mac, macOS 15 or later
- Xcode 27 to build from source
- Python 3.12+ and npm for the bundled helpers (`Tools/prepare_runtime.py`
  downloads the pinned Node runtime that ships inside the app)
- Optional: a signed-in [Codex](https://github.com/openai/codex) or
  [Claude Code](https://claude.com/claude-code) CLI for Compare and Fix

## Build and run

```sh
python3 Tools/prepare_runtime.py
open webframes.xcodeproj
```

Choose your own team under Signing & Capabilities (the project is set up for
the maintainer's Developer ID), then run the `webframes` scheme. Builds from
source do not receive Sparkle updates signed for the official release.

## Tests

```sh
npm ci --ignore-scripts --prefix Tools/component-catalog
npm test --prefix Tools
xcodebuild test -project webframes.xcodeproj -scheme webframes \
  -destination 'platform=macOS,arch=arm64' -only-testing:webframesTests \
  CODE_SIGNING_ALLOWED=NO
```

CI runs the same checks (`.github/workflows/ci.yml`).

## Layout

| Path | What it is |
| --- | --- |
| `webframes/` | The AppKit app: canvas, frames, comments, document format, Compare and Fix |
| `Tools/` | Node helpers bundled into the app: agent bridge, comments MCP, component catalog ([details](Tools/README.md)) |
| `Tools/release/`, `Tools/updates/` | Maintainer release and Sparkle update scripts |
| `Examples/` | Demo projects for the component catalog and project map |
| `webframesTests/` | Unit tests (Swift Testing) |

Project files are `.webframes` packages: `document.json` plus an `images/`
folder. See `webframes/DocumentPackage.swift`.

## Security

Agents get a bounded, read-only snapshot of your source; only the Apply button
in Web Frames writes files. See [SECURITY.md](SECURITY.md) to report a
vulnerability.

## License

[Functional Source License 1.1, Apache 2.0 future license](LICENSE.md)
(FSL-1.1-ALv2). You may use, modify and redistribute the code for any
purpose except offering a competing commercial product or service; each
version becomes available under the Apache License 2.0 two years after its
release. The Web Frames name and icon are not covered by the license.
Third-party components are listed in `webframes/ThirdPartyNotices.txt`.

© 2026 Egor Sazanov
