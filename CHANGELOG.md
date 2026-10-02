# Changelog

User-facing changes, newest first. Sparkle release notes are generated from
this file (see Tools/updates/README.md), so write entries for users, not for
reviewers. Internal refactors and test-only changes do not belong here.

## 1.1.4 (9) — 2026-10-02

### Added
- Tidy Up (⌃⌥T, Arrange menu and the alignment bar), like in Figma: lays
  the selected frames out in an even grid with equal gaps, keeping their
  reading order and roughly their current shape. With fewer than two frames
  selected it tidies the whole board. Undoable.

### Fixed
- A frame's controls (toolbar, link handles, resize grips) are never hidden
  under another frame. They appear while the frame is hovered, selected or
  a link target, and stay above every frame; controls of a covered frame no
  longer show through or catch clicks meant for the frame on top.

## 1.1.3 (8) — 2026-10-02

### Fixed
- Connect Codex now finds the signed-in coding agent bundled with current
  ChatGPT desktop releases. It could incorrectly ask you to install Codex
  even when it was already installed and signed in.

## 1.1.2 (7) — 2026-09-30

### Added
- Area comments, like in Figma: in comment mode, drag across a frame to
  select a region instead of clicking a point. The region is outlined on
  the frame and moves with the page; Fix, copied comments and the comments
  MCP tell the agent the region and the elements inside it.
- Window › Projects (⇧⌘P) shows the project list while projects are open,
  so another project opens in its own window.

### Changed
- In comment mode the hover outline stays inside the frame and follows its
  shape: all four sides are visible for elements larger than the frame, and
  its corners match the frame's rounded bottom.
- The Comments sidebar is a standard list: a circle in the comment's color
  resolves it (as in Reminders), rows show the number, frame and text,
  Copy / Resolve / Delete are in the right-click menu, Reset Comment
  Numbers is under the ⋯ menu, and Fix keeps its accent color with a menu
  button beside it for Copy All, Download Markdown and the agent choice.
- Each additional project window opens slightly offset instead of exactly
  covering the previous one.
- The dock, frame toolbars and comment cards use real Liquid Glass on
  macOS 26 and later.
- The comment card is built from standard controls: a resolve button in
  its title bar (as in Figma), a system menu for Copy and Delete, a plain
  text field with a hint, and a standard Save button (⌘Return).

### Fixed
- Dock buttons (Select, Hand and the rest) respond to every click. The
  canvas could not tell that a click was on the dock, so in Hand mode the
  click started a pan instead of switching tools.
- Clicking a dock button no longer leaves a blue focus ring on it.

## 1.1.1 (6) — 2026-09-29

### Added
- Layer order like Figma: Bring Forward ⌘], Send Backward ⌘[, Bring to
  Front ⌥⌘], Send to Back ⌥⌘[ (Arrange menu).
- File › Reduce Image Sizes… shrinks the screenshots already in a project
  (undoable). A board of 63 iPhone screenshots went from 95 MB to 12 MB.

### Changed
- New screenshots are stored at the size that is actually used: at most
  2048 px on the long side (page captures: 1440 px wide), which is still
  more than coding agents read. Picture frames may be stored as
  high-quality JPEG; comment screenshots stay PNG. Frames keep their size
  on the canvas.
- Panning, zooming and dragging frames are much smoother on busy boards:
  cards move without re-laying out their contents, the dot grid is drawn
  once and slid, dragging updates only the frames and links being moved,
  and links keep their route while zooming until you pause.

### Fixed
- A frame's top corners no longer show gaps under its title bar when the
  dock or a panel overlaps the frame.
- Clicking overlapping frames in comment mode places the pin on the frame
  that is on top.
- Shift- or ⌘-dragging a frame in a selection moves the whole selection;
  Shift/⌘-clicking without dragging still removes it from the selection.

## 1.1.0 (5) — 2026-09-27

### Added
- **Help › Open Sample Project** builds the Northstar sample with a
  reference, so Compare is two clicks away without any setup.
- View menu with every canvas shortcut: Zoom In/Out (⌘= / ⌘-), Zoom to Fit
  (⌘0), Zoom to Selection (P), Select (V), Hand (H), Comment Mode (C),
  Add Frame (F), Show/Hide Sidebar (⌃⌘S), Show/Hide Comments (⌃⌘I),
  Flow / Library (⌘1 / ⌘2).
- Help menu: Getting Started, Keyboard Shortcuts, Open Sample Project,
  Release Notes.
- File › Open… and Open Recent.
- One explicit approval per project folder before Web Frames runs its dev
  server, builds Library previews or sends its source to Codex. Settings
  lists approved folders with Revoke and Revoke All.

- Choose the coding agent in Settings: Codex or Claude Code, each with an
  optional model. Compare and Fix comments work the same way with either,
  through its own saved sign-in and the same read-only guard rails; buttons
  and messages use the chosen name ("Fix with Claude").

- Align & Distribute is a row of icon buttons above the selection instead of
  a menu, with Figma's shortcuts: ⌥A ⌥H ⌥D (left, horizontal centers,
  right), ⌥W ⌥V ⌥S (top, vertical centers, bottom), ⌃⌥H ⌃⌥V (distribute).
  The same commands are in the new Arrange menu.

- Link bends can be moved: drag a middle segment of a connector along its
  axis; the route keeps your bends when frames move. Double-click the link
  to go back to automatic routing. Undoable.
- Fix's menu chooses the agent to send comments to (Codex or Claude Code);
  the button follows the choice.

### Changed
- Image frames no longer show the desktop/mobile presets, which only apply
  to live pages.
- Distribute buttons appear from three selected frames instead of sitting
  greyed out.
- The comments panel button uses a conversation icon; comment mode uses a
  single "add comment" bubble.
- Compare's settings popover lists coding agent, source folder, sample
  project and run evidence as labeled rows with plain buttons.
- Projects are saved as packages: a `.webframes` item that holds
  `document.json` and an `images/` folder. Screenshots are stored once as
  image files instead of base64 text, so projects are smaller and saving
  does not rewrite unchanged images. Projects from 1.0.1 open as before and
  are converted on the next save; 1.0.1 cannot open converted projects.
- Settings no longer shows OpenAI, Anthropic and Gemini key cards: no
  feature uses those keys yet. Saved keys stay in Keychain.
- New Frame moved from ⌘T (the system Fonts shortcut) to ⇧⌘N.
- Pan and zoom stay smooth on boards with many comments and links:
  trackpad updates are applied once per display frame, and link routes are
  reused while panning instead of being searched again.
- The Start window opens instantly even with large projects.
- Only the newest sample project folder is kept on disk.

- A project saved by a newer Web Frames is refused with an explanation
  instead of being opened and re-saved in an older format.

### Removed
- The hidden local-folder frame source (`wf-local://`). It had no UI, and
  its file handler was reachable from every web frame. Old frames that used
  it show "Unsupported source".

### Security
- Fix with Codex asks a second time before changing `package.json`, build
  configs, PostCSS or tsconfig files, never reads credential-like files, and
  lists every file it sent in the review. Frame URLs sent to Codex lose
  passwords and token parameters.
- Frames load only http(s), GitHub and image sources; a shared project can
  no longer show local files. Only the page itself (not embedded iframes)
  can talk to Web Frames, with size limits.

- Run evidence (screenshots, page structure, source before/after) moved
  to one owner-only folder, keeps the 20 most recent runs for at most 30
  days, and can be cleared in Settings. The Codex connector deletes each
  job's source snapshot as soon as the job ends.

### Fixed
- Projects saved in the new format open from the Start window even when an
  older Web Frames is still installed; open errors now say why.
- The toolbar's comments-panel and Settings buttons work again; clicks in
  the toolbar no longer start a selection on the canvas underneath.
- Image frames move when dragged by the picture, not only the header; this
  no longer pulls out a copy of the image that lands as a duplicate frame.
  The cursor over the header stays steady.
- Dropped images land where you release them, pasted images in the middle
  of the visible canvas, and both are selected.
- Compare and Fix explain that a coding agent must be connected and offer
  to open Settings, instead of opening Settings unasked.
- Typing a space in the GitHub tab's owner or repository field no longer
  crashes Web Frames.
- The Library preview server starts even when its usual port is taken.
- Comment pins land where you click on narrow (mobile) frames and at any
  zoom level; they were offset vertically.
- A project or source folder that was moved or renamed is found again and
  remembered under its new path instead of being lost after relaunch.
- New Frame from the menu did nothing.
- Closing a project now releases its web views, and the dev server and
  Library helper stop even if Web Frames quits unexpectedly.
- Project map routes and component pages were wrong when the project folder
  was reached through a symbolic link.

## 1.0.1 (4) — 2026-09-23

- More resilient Library: component errors stay in their own previews,
  missing sample data is explained, previews can be retried, and Refresh
  restarts the built-in preview server.
- Arrange frames together: select with Shift/⌘-click, a selection rectangle
  or ⌘A; move, align, distribute and delete a group with Undo.
- Optional comment resolution through MCP: enable “Allow agents to resolve
  comments” in Settings › Claude · MCP to let local agents resolve or reopen
  comments in an open project. Off by default; changes record their author
  and time and support Undo.
