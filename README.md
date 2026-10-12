# Web Frames

A native macOS workspace for web projects and AI coding agents. Put live
pages, localhost routes and components on an infinite canvas, pin comments
with DOM context, and hand them to Codex or Claude Code for fixes you review
before anything is written.

Download the signed build at [webframes.pro](https://www.webframes.pro).
Current release: **1.1.7 (12)**, Developer ID signed and Apple notarized.
See the [changelog](CHANGELOG.md) for changes and MCP compatibility notes.

## What you can do

- Inspect live web pages, localhost routes and component previews on one canvas.
- Pin comments to elements or screenshot regions, then review an agent's patch
  before Apply. Undo restores the previous source.
- Collect variants in a section, choose the reference yourself and give the
  section a task for your coding agent.
- Connect a local MCP client with the setup wizard. Comment status and screenshot
  updates require separate permissions, both off by default.
- Store a screen flow and deeplink on an image frame. Your external agent can
  run the flow and replace that frame's screenshot; Undo and saved boards retain
  the image you choose. Web Frames does not control an emulator itself.
- Align frames with magnetic guides and import screenshot batches as a grid.

Component previews depend on the project's providers and sample data. Server
authentication and database access may need a mock or the project's live page.

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

Built-in Compare and Fix give the agent a bounded, read-only source snapshot;
the Apply button writes the reviewed patch. External MCP clients can read board
context and, with your explicit settings, change comment status or frame images.
The MCP server never writes your source files. See [SECURITY.md](SECURITY.md)
to report a vulnerability.

## License

[Functional Source License 1.1, Apache 2.0 future license](LICENSE.md)
(FSL-1.1-ALv2). You may use, modify and redistribute the code for any
purpose except offering a competing commercial product or service; each
version becomes available under the Apache License 2.0 two years after its
release. The Web Frames name and icon are not covered by the license.
Third-party components are listed in `webframes/ThirdPartyNotices.txt`.

© 2026 Egor Sazanov
