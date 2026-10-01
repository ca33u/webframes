# Web Frames tooling: coding-agent bridge and comments MCP

Compare and Fix comments run through a coding agent chosen in **Settings → Coding agent**: **Codex** (default model `gpt-6-astra`) or **Claude Code** (its default model unless you enter one). Web Frames starts the agent's own CLI with your saved sign-in; it never asks for an API key, removes API-key variables from the agent's environment, and runs use that account's limits. Below, "Codex" describes either agent: both get the same read-only snapshot through `context-mcp.mjs`, no shell or web tools, and structured JSON output. `codex-bridge.mjs` holds the per-provider command lines (`PROVIDERS`).

## Comments MCP for Codex and Claude Code

`comments-mcp.mjs` is a separate, read-only-by-default MCP server for the comments saved in Web Frames projects. It exposes five tools:

- `list_projects` — find saved Web Frames projects and unresolved counts.
- `list_comments` — read the unresolved or resolved list with frame, URL, viewport, selector, and source-root context.
- `get_comment` — read one full comment and return its attached screenshot when available.
- `get_agent_brief` — produce a compact implementation brief for a coding agent.
- `set_comment_status` — resolve or reopen comments in an open project; off until **Allow agents to resolve comments** is enabled (see below).

In **Settings → Claude · MCP**, use **Copy Desktop config** or **Copy Code command**. Generated configuration points to Node and the read-only MCP helper inside the installed Web Frames app; no separate Node installation is needed. Install Web Frames in Applications before copying this configuration.

For a manually configured external Codex client, use the same bundled executable and helper paths from this configuration as a stdio MCP server. Web Frames does not silently change another application's MCP settings.

Then open the source project in the coding agent and ask it to use `get_agent_brief`, inspect the source, implement the open comments, and report the comment ids it addressed. The MCP server never writes source files. With **Settings → Claude · MCP → Allow agents to resolve comments** enabled, `set_comment_status` can resolve or reopen comments in an open project. The running app validates the batch against current memory, records the actor/time, saves through NSDocument and supports Undo; it never overwrites the project from a second writer. The opt-in allows local MCP clients running as this macOS user. It does not grant source edits or screen capture. Requests expire after 12 seconds; if no confirmation arrives, read status before retrying.

To expose only one Web Frames document, append `--project /absolute/path/to/project.webframes` to the MCP command. Projects are packages (`document.json` plus `images/`) since format version 2; the server reads both packages and 1.0.1 single-file projects. Web Frames autosaves comments, so the next MCP call reads the latest saved document state.

## Fix with your agent

The Comments sidebar shows **Fix with Codex** (or **Fix with Claude**, after the chosen agent) whenever the document has open comments. It uses the same paired local connector and saved ChatGPT/Codex sign-in as visual comparison:

1. Import the source project so the Web Frames document has a source root.
2. Connect the local Codex connector once from comparison settings.
3. Add one or more comments and choose **Fix with Codex**.
4. Codex reads a bounded source snapshot and returns exact replacements for existing HTML, CSS, JS/JSX, TS/TSX or JSON files. It cannot write source through the connector; only Apply in Web Frames writes.
5. Review the proposed files and replacements, then explicitly Apply or discard them.

A single reviewed operation is limited to 8 existing files, 8 replacements per file and 32 replacements total. Web Frames checks every source hash before writing anything, captures the addressed live frames before Apply, saves approval evidence, reloads project frames, and captures fresh after evidence. It offers Undo while the applied files remain unchanged. Comments stay open until verified and resolved by the user, or by an agent when comment-status permission is explicitly enabled.

## Comment status requests

`set_comment_status` accepts `{ "project": "project-id", "ids": ["comment-id"], "resolved": true }`.
Use `false` to reopen. Permission is off by default and checked on every request. Keep the project open in Web Frames. A deleted or edited comment rejects the whole batch; read comments again before retrying. The request inbox is under `~/Library/Application Support/Web Frames/MCP Requests/` in per-project directories with owner-only permissions. This is same-user local IPC, not a remotely exposed service.

## Start

Requirements: Apple Silicon, macOS 15 or later, a signed-in Codex installation with GPT-6 Astra access, and Web Frames. Node and local helpers are bundled. The previous live smoke test used Codex 0.154.0-alpha.6.2; compatibility with other Codex CLI versions needs verification.

1. Install Web Frames in Applications and open or create a project.
2. In Settings, click **Connect Codex**. Web Frames starts its private local connector automatically; no terminal or connection-file picker is needed. If Codex is installed somewhere unusual, developers can set `WEBFRAMES_CODEX_BINARY` to its executable path.
3. **Open sample project** builds an isolated Northstar dashboard, freezes a correct reference, then introduces three CSS defects.
4. Select two frames with Shift-click. The canvas shows **Compare**, the reference and implementation labels, and **Swap reference**. Compare sends screenshots, DOM and the selected source snapshot through Codex; findings become comments pinned to the implementation. Click a pin to read it.
5. **Review fix…** opens a sheet with the exact diff. **Apply reviewed fix** writes one CSS file, reloads the frame, captures a fresh image, and asks Astra to verify every finding. Independent fixture checks also cover overflow, card width, heading size, button color, and a button click.
6. **Undo fix** restores the exact source if nobody edited it after Apply. **Discard proposal** makes no source changes.

For another local page, choose its source folder in **Setup…** and select two loaded frames of identical logical dimensions. Start that project's dev server from its sidebar menu, or use an already running server. Production URLs do not grant access to production source or deployment.

## Boundaries

- Codex receives a bounded snapshot, not the original source folder. MCP offers only `search_code` and `read_code`. Shell, hooks, web search and multi-agent tools are disabled; filesystem sandbox is read-only. Only the native Apply button can write the actual source.
- A visual Compare proposal can modify one existing CSS file, at most eight exact replacements. A Fix with Codex proposal can modify existing HTML, CSS, JS/JSX, TS/TSX or JSON files within the limits above; edits to `package.json`, `*.config.*`, PostCSS and tsconfig files are flagged in review and need a second confirmation before Apply. Files whose names look like credentials (`*credentials*`, `*service-account*`, `*private-key*`…) and hidden files are never read or sent; the review lists every file that was sent. Frame URLs sent to Codex have user info and token-like query parameters removed. Hashes reject stale edits; symlinks, hidden paths, traversal and generated directories are excluded.
- Source snapshot: up to 200 files, 128 KB per file, 512 KB total. Supported reads: HTML/CSS/JS/JSX/TS/TSX. Select a small relevant source folder. Excluded filenames alone are not a secret detector: review the selected source before sending it.
- Local connector binds only to 127.0.0.1, requires a random pairing token, rejects browser Origin headers and runs one job at a time. Never share `connection.json` or commit `.codex-bridge/`.
- Pairing is stored in Keychain. A previously connected app-owned connector is restarted automatically with fresh credentials on launch. Disconnect stops it and removes saved pairing. Source folder selection and Undo state are session-only. After restarting Web Frames, open a fresh sample; old localhost frame URLs will no longer serve.
- Cancellation after writing leaves an applied, unverified change and keeps Undo available. No silent model substitution, auto-deploy, or background source writes.

## Evidence and recovery

**Setup… → Run evidence…** opens the local run directory containing reference/before/after images and DOM, the proposal, reviewed patch, original and changed CSS, approval receipt, verification, and event timestamps. Artifacts are under `~/Library/Application Support/Web Frames/AstraRuns` with owner-only permissions. Web Frames keeps the 20 most recent runs and nothing older than 30 days; **Settings → Local evidence → Clear Evidence** removes them all. The connector deletes each job's working folder (source snapshot, screenshots) as soon as the job ends.

If the app quits after Apply, recover manually from that run's `before.css`; compare current content with `after.css` before restoring to avoid overwriting subsequent edits. Automatic recovery across restarts is not implemented.

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

## Release packaging

See `release/README.md` for bundled helpers, Developer ID signing, notarization, installer creation and update-feed preparation.
