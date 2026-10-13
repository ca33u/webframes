# Web Frames

A native macOS workspace for web projects and AI coding agents. Put live
pages, localhost routes and components on an infinite canvas, pin comments
with DOM context, and hand them to Codex or Claude Code for fixes you review
before anything is written.

Download the signed build at [webframes.pro](https://www.webframes.pro).
Current public release: **1.1.8 (13)**, Developer ID signed and Apple notarized,
including the complete native iOS and Android simulator workflow.
See the [changelog](CHANGELOG.md) for changes and MCP compatibility notes.

## What you can do

- Inspect live web pages, localhost routes and component previews on one canvas.
- Pin comments to elements or screenshot regions, then review an agent's patch
  before Apply. Undo restores the previous source.
- Collect variants in a section, choose the reference yourself and give the
  section a task for your coding agent.
- Connect a local MCP client with the setup wizard. Comment status and screenshot
  updates and native simulator captures require separate permissions, each off by default.
- Capture iOS Simulator and Android Emulator screens directly. Choose an app,
  save tap/wait/type/swipe actions and refresh the same image frame with Undo.
  Uses local Xcode or Android SDK/JDK; no tapflow account or external service. Agents can run the
  saved recipe through `capture_simulator_frame` with a separate opt-in. Refresh
  selected screens or all saved recipes in mixed iOS/Android batches, with
  per-screen results and one Undo; agents use `capture_simulator_frames`.
- Store legacy flow YAML and deeplinks for optional external runners too.
- Align frames with magnetic guides and import screenshot batches as a grid.

Component previews depend on the project's providers and sample data. Server
authentication and database access may need a mock or the project's live page.

Native simulator capture is included in 1.1.8. In Add Frames → Image, choose **Capture
from Simulator…**, or select an image and use **Simulator capture settings**.
Use **Refresh from simulator** to repeat its recipe. Choose iOS Simulator or
Android Emulator in capture settings. Xcode/iOS runtime or Android SDK/JDK are
required; Web Frames can start an existing simulator or emulator and control an
installed app. It does not create backend accounts or execute arbitrary YAML. **Record Actions…** captures clicks, vertical swipes and text entry inside
Web Frames, so screen scenarios can be assembled without typing selectors.
**Test State…** saves an account label, test data, theme, launch arguments and
preparation actions with the frame. **Start live preview** shows only the selected
frame using its saved recipe, without saving video or replacing its screenshot.
Enable **Build and install before capture** to rebuild an Xcode scheme or Gradle
module/variant and update-install the app before recording or refreshing screens.
Local build scripts require separate project permission; existing app data is kept.
See the [Simulator Capture guide](docs/simulator-capture.md) for setup and agent permissions.

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
