# Web Frames tooling: coding-agent bridge and comments MCP

Compare and Fix comments run through a coding agent chosen in **Settings → Coding agent**: **Codex** (default model `gpt-6-astra`) or **Claude Code** (its default model unless you enter one). Web Frames starts the agent's own CLI with your saved sign-in; it never asks for an API key, removes API-key variables from the agent's environment, and runs use that account's limits. Below, "Codex" describes either agent: both get the same read-only snapshot through `context-mcp.mjs`, no shell or web tools, and structured JSON output. `codex-bridge.mjs` holds the per-provider command lines (`PROVIDERS`).

## Comments MCP for Codex and Claude Code

`comments-mcp.mjs` is a separate, read-only-by-default MCP server for the comments and frames saved in Web Frames projects. It exposes twelve tools:

- `list_projects` — find saved Web Frames projects and unresolved counts.
- `list_sections` — read manually collected pools, their tasks, member ids and chosen references.
- `get_section` — read one section task/reference and a page of its member frame ids.
- `list_comments` — read the unresolved or resolved list with frame, URL, viewport, selector, and source-root context.
- `get_comment` — read one full comment and return its attached screenshot when available.
- `get_agent_brief` — produce a compact implementation brief for a coding agent.
- `set_comment_status` — resolve or reopen comments in an open project; off until **Allow agents to resolve comments** is enabled (see below).
- `list_frames` — list frame ids, types, dimensions, current image hashes, native `simulatorCapture` recipe summaries and legacy `flow`/`deeplink` fields.
- `get_frame` — inspect a frame and its current image, including an updated screenshot.
- `update_frame_image` — replace one existing image frame with a captured PNG/JPEG; off until **Allow agents to update frame images** is enabled.
- `capture_simulator_frame` — run one user-saved native iOS/Android recipe and update its image; off until **Allow agents to capture simulator screens** is enabled.
- `capture_simulator_frames` — run 1–20 saved recipes, with per-frame results and one Undo for successful updates; uses the same native capture permission.

In **Settings → Claude · MCP → Set up MCP…**, choose Claude Desktop, Claude Code
or another stdio client, and one saved board or all boards. **Test connection**
checks the bundled helper locally without an AI run. Review the client, scope,
destination and command before **Install**. The installer merges only its named
entry, preserves other servers/settings, creates an owner-only backup beside an
existing config, and rejects malformed configs or edits made since review.
Claude Code installation uses user scope; a selected board still limits the data
the helper exposes. Restart Claude Desktop or check `claude mcp get <server-name>`
and `/mcp` in Claude Code. Other clients get a config to copy.

**Copy Desktop config** and **Copy Code command** remain available. Generated
configuration points to Node and the MCP helper inside the installed app; no
separate Node installation is needed. Keep Web Frames in Applications before
setup so client paths stay valid. Setup does not enable comment writes, image updates or native captures.

Client config formats/scopes follow the [Claude Code reference](https://code.claude.com/docs/en/mcp)
and [MCP local-server guide](https://modelcontextprotocol.io/docs/develop/connect-local-servers).

### Large lists (MCP 0.2)

`list_projects`, `list_frames`, `list_comments` and `list_sections` accept `limit`
(1–200, default 100) and an opaque `cursor`. Results contain their named array
and `pagination: {total, returned, limit, nextCursor}`. **Compatibility change:**
`list_projects` now returns `{projects, pagination}` instead of a bare array.
Pass `nextCursor` to the same tool/project/filter until it is null. Saved-data
changes invalidate the cursor; restart without it. Each page also has a byte
budget, so it may return fewer items than `limit`. Oversized items keep their id
and `detailsOmitted`; use `get_comment`, `get_frame` or `get_section` for details.
`get_section` pages its member ids. Empty lists have total 0 and nextCursor null.

`get_agent_brief` accepts the same comment cursor/limit plus `section_cursor` for
section tasks. It prints both pagination records; continue each independently
and inspect all pages before deciding the work is complete. Single-item read
tools return full context and screenshots. Reconnect clients after updating the
app so they discover the new schemas.

Offline integration check: `python3 Tools/release/mcp_smoke.py /path/to/Web\ Frames.app`.
It exercises large datasets with an independent Python stdio client and, when
installed, Claude Code in a temporary `CLAUDE_CONFIG_DIR`; no real client config
or AI session is used.

For a manually configured external Codex client, use the same bundled executable and helper paths from this configuration as a stdio MCP server. Web Frames does not silently change another application's MCP settings.

Then open the source project in the coding agent and ask it to use `get_agent_brief`, inspect the source, implement the open comments, and report the comment ids it addressed. The MCP server never writes source files. With **Settings → Claude · MCP → Allow agents to resolve comments** enabled, `set_comment_status` can resolve or reopen comments in an open project. The running app validates the batch against current memory, records the actor/time, saves through NSDocument and supports Undo; it never overwrites the project from a second writer. The opt-in allows local MCP clients running as this macOS user. It does not grant source edits or screen capture. Requests expire after 12 seconds; if no confirmation arrives, read status before retrying.

To expose only one Web Frames document, append `--project /absolute/path/to/project.webframes` to the MCP command. Projects are packages (`document.json` plus `images/`) since format version 2; the server reads both packages and 1.0.1 single-file projects. Web Frames autosaves comments, so the next MCP call reads the latest saved document state.

## Fix with your agent

The Comments sidebar shows **Fix with Codex** (or **Fix with Claude**, after the chosen agent) whenever the document has open comments. It uses the same paired local connector and the chosen agent’s saved sign-in as visual comparison:

1. Import the source project so the Web Frames document has a source root.
2. Choose Codex or Claude Code in **Settings → Coding agent** and connect it.
3. Add one or more comments and choose **Fix with Codex**.
4. Codex reads a bounded source snapshot and returns exact replacements for existing HTML, CSS, JS/JSX, TS/TSX or JSON files. It cannot write source through the connector; only Apply in Web Frames writes.
5. Review the proposed files and replacements, then explicitly Apply or discard them.

A single reviewed operation is limited to 8 existing files, 8 replacements per file and 32 replacements total. Web Frames checks every source hash before writing anything, captures the addressed live frames before Apply, saves approval evidence, reloads project frames, and captures fresh after evidence. It offers Undo while the applied files remain unchanged. Comments stay open until verified and resolved by the user, or by an agent when comment-status permission is explicitly enabled.

## Comment status requests

`set_comment_status` accepts `{ "project": "project-id", "ids": ["comment-id"], "resolved": true }`.
Use `false` to reopen. Permission is off by default and checked on every request. Keep the project open in Web Frames. A deleted or edited comment rejects the whole batch; read comments again before retrying. The request inbox is under `~/Library/Application Support/Web Frames/MCP Requests/` in per-project directories with owner-only permissions. This is same-user local IPC, not a remotely exposed service.

## Native simulator capture and screenshot refresh

For the built-in workflow, save a recipe using **Add Frames → Image / PDF → Capture from Simulator…**, or **Simulator capture settings** on an existing image. Web Frames supports iOS and Android, action recording, optional local build/install, test-state preparation and selected-frame live preview. See the [Simulator Capture guide](../docs/simulator-capture.md).

For agents, enable **Allow agents to capture simulator screens**. `capture_simulator_frame` runs the saved recipe; `capture_simulator_frames` accepts 1–20 unique frame ids and can mix platforms. Inspect every result: a completed batch can contain failed screens. Agents cannot supply a new recipe, build command or test state. Local build permission is separate. Direct native UI capture does not require the MCP permission.

### External screenshot files (optional)

Enable **Settings → Claude · MCP → Allow agents to update frame images** and keep the Web Frames project open. This is separate from permission to resolve comments; both are off by default.

The external coding agent builds and launches the application using its own tools, opens the intended screen in its simulator/emulator and captures a screenshot. It then calls:

```json
{"project":"project-id","frame_id":"frame-id","image_path":"/absolute/path/to/screen.png"}
```

Pass these arguments to `update_frame_image`. Find `frame_id` through `list_frames` or `frame.id` in a comment. PNG and JPEG files are accepted up to 8 MiB, 16,384 pixels per side and 32 million pixels total. The MCP server copies the file bytes into a bounded request, so Web Frames does not need access to a temporary simulator path. The app validates the image and the existing frame's byte hash, updates the open document and confirms only after saving. A changed or deleted frame rejects the request; read its current state before retrying. Identical image retries do not duplicate undo history. If confirmation times out, use `get_frame` to check the saved image before retrying.

The frame keeps its id, label, position, size, comments and links. Other frames sharing the old image remain unchanged. Original comment screenshots are retained as before evidence: `get_comment` reads those; `get_frame` reads current frame pixels. Updates record `imageUpdatedBy`/`imageUpdatedAt` and support **Undo Update Frame Image**. Updating pixels does not resolve comments. Verify the resulting screen before separately calling `set_comment_status` when allowed.

Use **Edit screen flow…** in an image frame’s floating toolbar to save optional `flow` and `deeplink` fields. `flow` accepts inline runner YAML or a file path relative to the source project (or an absolute path). The editor saves recipe text without executing it and supports Undo/Redo. Both fields survive image replacement and document reopening, and are returned by `list_frames` and `get_frame`; `get_agent_brief` explains the refresh sequence. Keep credentials out of shared recipes.

For an optional external runner such as tapflow, the agent reads the legacy recipe, builds/installs as needed, calls `run_flow`, captures with `screenshot`, and passes the resulting absolute PNG/JPEG path to `update_frame_image`. A failed flow or capture must leave the existing frame image in place. A legacy `flow`/`deeplink` is a navigation hint for that external runner; Web Frames does not execute legacy YAML. Native `simulatorCapture` recipes have their own supported deeplink handling. URL credentials and token-like query parameters are removed from deeplinks returned by MCP, as for frame URLs.

### Collect variants and choose a reference

Select frames and press **Shift-S** to wrap them in a section, or draw an empty
section and move frames into it. Right-click its canvas title → **Choose Reference**
and select one of its members. A star marks the reference in the title and sidebar.
Use **Edit Agent Task…** to describe what to unify. Both edits save with the board
and support Undo/Redo. **Clear Reference** removes the choice.

`list_sections` returns `frameIds`, `task`, `referenceFrameId`, `referenceStatus`
and the available reference's id/label. `list_frames` also returns `sectionId` and
`isReference`. If the chosen frame leaves the section or is deleted, its saved id
is retained for Undo, but its status becomes `unavailable`; agents must ask for a
reference instead of selecting another. `get_agent_brief` includes the pools and
the unify recipe, including verification and reporting remaining differences.

The built-in Fix connector does not run builds or control simulators. Native capture, batches, build/install, test states and selected-frame live preview are available through the app’s separate simulator workflow. Swift/Kotlin source edits use an external coding agent’s own source tools and review.

## Start

Requirements: Apple Silicon, macOS 15 or later, Web Frames and a signed-in Codex or Claude Code installation. The selected model must be available to your account. Use the model field to choose one; leaving it empty uses Web Frames’ Codex default or Claude Code’s default. Node and local helpers are bundled.

1. Install Web Frames in Applications and open or create a project.
2. In **Settings → Coding agent**, choose Codex or Claude Code and click its **Connect** button. Web Frames starts its private local connector automatically; no connection-file picker is needed. Unusual CLI locations can be supplied through `WEBFRAMES_CODEX_BINARY` or `WEBFRAMES_CLAUDE_BINARY`.
3. In **Comparison settings**, use **Sample project → Open**. This builds an isolated Northstar dashboard, freezes a correct reference, then introduces three CSS defects.
4. Select two frames with Shift-click. The canvas shows **Compare**, the reference and implementation labels, and **Swap reference**. Compare sends screenshots, DOM and the selected source snapshot through Codex; findings become comments pinned to the implementation. Click a pin to read it.
5. **Review fix…** opens a sheet with the exact diff. **Apply reviewed fix** writes one CSS file, reloads the frame, captures a fresh image, and asks the chosen coding agent to verify every finding. Independent fixture checks also cover overflow, card width, heading size, button color, and a button click.
6. **Undo fix** restores the exact source if nobody edited it after Apply. **Discard proposal** makes no source changes.

For another local page, choose **Source folder → Choose…** in **Comparison settings** and select two loaded frames of identical logical dimensions. Start that project's dev server from its sidebar menu, or use an already running server. Production URLs do not grant access to production source or deployment.

## Boundaries

These source-write controls apply to the built-in Compare/Fix connector. Independently running coding agents retain their own tools and permissions; the Comments MCP server itself never edits source.

- Codex receives a bounded snapshot, not the original source folder. MCP offers only `search_code` and `read_code`. Shell, hooks, web search and multi-agent tools are disabled; filesystem sandbox is read-only. Only the native Apply button can write the actual source.
- A visual Compare proposal can modify one existing CSS file, at most eight exact replacements. A Fix with Codex proposal can modify existing HTML, CSS, JS/JSX, TS/TSX or JSON files within the limits above; edits to `package.json`, `*.config.*`, PostCSS and tsconfig files are flagged in review and need a second confirmation before Apply. Files whose names look like credentials (`*credentials*`, `*service-account*`, `*private-key*`…) and hidden files are never read or sent; the review lists every file that was sent. Frame URLs sent to Codex have user info and token-like query parameters removed. Hashes reject stale edits; symlinks, hidden paths, traversal and generated directories are excluded.
- Source snapshot: up to 200 files, 128 KB per file. Compare has a 512 KB total budget and reads HTML/CSS/JS/JSX/TS/TSX; comment Fix has a 2 MB total budget and also reads JSON. Select a small relevant source folder. Excluded filenames alone are not a secret detector: review the selected source before sending it.
- Local connector binds only to 127.0.0.1, requires a random pairing token, rejects browser Origin headers and runs one job at a time. Never share `connection.json` or commit `.codex-bridge/`.
- Pairing is stored in Keychain. A previously connected app-owned connector is restarted automatically with fresh credentials on launch. Disconnect stops it and removes saved pairing. Temporary comparison source selection and source-Apply Undo are session-only; this does not describe saved native capture recipes or persisted image-update Undo. After restarting Web Frames, open a fresh sample; old localhost frame URLs will no longer serve.
- Cancellation after writing leaves an applied, unverified change and keeps Undo available. No silent model substitution, auto-deploy, or background source writes.

## Evidence and recovery

**Comparison settings → Run evidence → Show in Finder** opens the local run directory containing reference/before/after images and DOM, the proposal, reviewed patch, original and changed CSS, approval receipt, verification, and event timestamps. Artifacts are under `~/Library/Application Support/Web Frames/AstraRuns` with owner-only permissions. Web Frames keeps the 20 most recent runs and nothing older than 30 days; **Settings → Local evidence → Clear Evidence** removes them all. The connector deletes each job's working folder (source snapshot, screenshots) as soon as the job ends.

If the app quits after Apply, Compare runs retain `before.css`/`after.css`. Comment Fix runs retain indexed `comment-fix-<index>-before.txt`/`after.txt` files and a `comment-fix-approval.json` path/hash mapping. Compare current content with the recorded after version before restoring anything, so newer edits are not overwritten. Automatic recovery across restarts is not implemented.

A saved successful run can be shown as **Recorded run** if account limits or network access prevent a live demo. Never present replay as live execution.

## Checks

```sh
npm test --prefix Tools          # Node helpers + component catalog
xcodebuild test -project webframes.xcodeproj -scheme webframes \
  -destination 'platform=macOS,arch=arm64' -only-testing:webframesTests
```

CI (`.github/workflows/ci.yml`) runs the same on every push and pull request,
skipping `KeychainHelperTests` and the real-localhost Astra test, which need a
login keychain and a window server; run those locally before a release.

The native localhost integration test covers capture → reviewed write → reload → independent checks → Undo. It uses a fixture patch; the separate live UI smoke test establishes the model path.

`WF02ScenarioTests` also covers PNG paste, Undo/Redo and package reopen. Its two
live tests are opt-in: they use the installed, signed-in Codex through a separate
temporary connector and send only synthetic fixture sources/screenshots. One
covers screenshot → source binding → real Fix → review → Apply → reload → Undo;
the other covers real Compare → Apply → agent verification → Undo. They consume
agent usage and remain disabled in ordinary/CI runs:

```sh
TEST_RUNNER_WEBFRAMES_LIVE_AGENT_SMOKE=1 xcodebuild test \
  -project webframes.xcodeproj -scheme webframesTests \
  -destination 'platform=macOS' -only-testing:webframesTests/WF02ScenarioTests
```

The 2026-10-12 Release UI smoke additionally exercised project import, two
localhost pages, point/area comments, the actual review/Apply/Undo controls,
button behavior and board reopen. Run artifacts are retained locally.

## Release packaging

See `release/README.md` for bundled helpers, Developer ID signing, notarization, installer creation and update-feed preparation.
