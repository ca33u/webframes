# Simulator Capture (1.1.8)

Web Frames captures iOS Simulator and Android Emulator screens locally, using
its own bundled XCTest / Android UiAutomation runners. No tapflow, server,
token or additional account is required.

1. For iOS, install Xcode and an iOS simulator runtime. For Android, install
   Android Studio with SDK Platform Tools, Emulator, Build Tools, an SDK platform
   and an AVD system image. Android Studio includes the required JDK. Install
   your app on the simulator/emulator, or choose its source project as described below.
2. To add a frame, open **Add Frames → Image → Capture from Simulator…**.
   To update an existing image, select it and choose **Simulator capture settings**
   (the iPhone icon in its toolbar).
3. Choose **iOS Simulator** or **Android Emulator**, then a device. **Start Simulator** starts a stopped device inside Web Frames.
   Choose **Current screen** for a quick snapshot, or an installed app for a recipe.
4. Add actions in order: **Tap**, **Wait for**, **Type text**, **Swipe up** or
   **Swipe down**. Tap and Wait use the exact visible label or accessibility
   identifier (Android also accepts the full resource id). Use unique identifiers
   for ambiguous controls. Type text uses the focused input; add a Tap first.
   On Android it sets that field's value and supports Unicode; if Compose omits
   focus, the only visible editable field is used. Multiple fields require focus. An optional
   deeplink opens before actions and is scoped to the selected app on Android.
5. Choose **Capture**, or **Save Recipe** on an existing frame. Later, click
   **Refresh from simulator** (the circular arrow) to repeat the saved recipe.

To rebuild your app automatically, enable **Build and install before capture**.
Choose an Xcode `.xcodeproj` / `.xcworkspace`, scheme and configuration for iOS;
choose the Gradle project folder containing `gradlew`, module (for example `app`
or `features:demo`) and variant (for example `Debug` or `DemoDebug`) for Android.
Enter the exact bundle / application ID; the app does not need to be installed
already. Debug is the default. Web Frames verifies the built product's identity
before installing it on the selected simulator. Android requires a universal
APK; split APK / app bundle installation is not supported.

**Allow Builds** authorizes this project's build scripts to execute locally.
This permission is separate from source sharing and agent capture. Use **Revoke
Build Permission** in the same settings to revoke it; moved projects need new
approval. A saved recipe alone cannot authorize execution. Project builds may
resolve their normal package dependencies. No distribution, signing upload or
publication command is run.

Capture and **Record Actions…** then run build → update-install → open app →
actions → screenshot. Installation preserves app data; it does not uninstall,
reset the app. Android version downgrades are rejected. Failed builds / installation / cancellation keep
the previous frame image. Cancellation stops local build processes but cannot
undo completed app installation or actions. A batch builds and installs each
unique project/settings/app/device combination once, then reuses it for that
batch's screens; the next refresh builds again so source edits are picked up.

To build the action list without typing selectors, choose an installed app (or configure a source build) and
click **Record Actions…**. Click controls or drag vertically on the device
preview; Web Frames identifies the control by its accessibility label or id.
Tap an editable field, enter text below the preview and choose **Type Text**
(or press Return in the input). Each action updates the preview and appears in
the recorded list. **Refresh Screen** updates the preview without adding an
action. This records interactions inside Web Frames; interactions in the
separate Simulator or Emulator window are not recorded.

**Use Recording** replaces the editor's action list. Review it, then choose
**Save Recipe** or **Capture** to save it on the frame. Closing or cancelling
the recorder leaves the old action list intact. Actions already performed on
the device remain in effect. The recorder uses the selected app, restart option
and deeplink; existing actions are not replayed when starting a new recording.
A recording accepts 30 actions and ends after 15 minutes. Controls need unique
accessibility labels or ids; ambiguous or unlabelled controls are rejected.
Password entry is not recorded. Use the app's existing test state for sign-in.
On Android, Type Text sets the field value; on iOS it types into the selected
field. Recording reserves the native runner until Use Recording or Cancel.

The first app capture builds Web Frames' runner locally and may take a minute.
Later runs reuse it. **Restart app** terminates and launches the selected app
before each capture; it does not clear its data. Leave it off to activate the
current session. Recipes are saved as plain document data, so avoid storing
passwords or other secrets in Type text or deeplinks.

An update preserves the frame id, title, size, position, comments, their original
screenshots and links. Undo and Redo survive saving and reopening the board.
Failed or cancelled capture keeps the old image. If the frame image or recipe
changes during capture, the result is rejected rather than overwriting that edit.
Capture runs sequentially; a second simultaneous run is rejected. Cancel stops
the local runner; actions already performed in the simulator are not rolled back.

To refresh several screens, select their image frames and choose **Arrange →
Update Selected Screenshots…**, or the refresh button in the selection toolbar.
**Arrange → Update All Simulator Screenshots…** includes every image frame with
a saved recipe. A batch accepts up to 20 frames and can mix iOS and Android;
larger boards should be refreshed in smaller selections. Screens run in board
order using the saved device and app. Results are staged until the batch ends,
then successful captures are applied and saved with one **Update Screenshots**
Undo action. The summary lists each success or failure. Missing recipes, failed
navigation and images/recipes changed during capture keep their old screenshots.
Cancel before apply discards all staged screenshots. Other captures cannot
interleave with the batch. Simulator actions already performed remain in effect.

For agents, enable **Settings → Allow agents to capture simulator screens**.
The `capture_simulator_frame` MCP tool accepts only a project and frame id, runs
the recipe saved by the user and saves the updated frame through the open app.
Agents cannot supply their own recipe with this tool. The separate permission
is off by default; turning it off cancels an active agent capture. Direct clicks
inside Web Frames do not require agent permissions. `list_frames` / `get_frame`
include the device, app and action count, without exposing typed text.
The `capture_simulator_frames` tool accepts `frame_ids` (1–20 unique ids), uses
the same permission and returns an `updated` count plus per-frame `results`.
All ids and saved recipes are checked before capture. It has a 15-minute deadline;
expiry or revoking capture permission before apply discards the staged batch.
An `ok: true` reply means the batch completed; inspect each result for failures.

Android discovers the standard ~/Library/Android/sdk, ANDROID_HOME / ANDROID_SDK_ROOT,
or the folder selected with **Choose Android SDK…**. A JDK can also be supplied
through JAVA_HOME. The first app capture builds and signs a small local runner
and installs it only on the selected emulator. Physical phones are not listed.
An app using FLAG_SECURE must allow screenshots through its own settings;
protected visible windows are rejected before replacing the frame. Dismiss
system permission dialogs before running an app recipe. Capture does not grant
permissions or disable app screenshot protection automatically.

Choose **Test State…** in capture settings to save a named test state on the
frame: account label, JSON test values, system/light/dark theme, optional launch
arguments, preparation actions and a required ready control. **Record Preparation…**
lets you assemble preparation by interacting with the same native recorder.
Use `{{account}}` or `{{data.key}}` in actions, launch arguments or the ready
selector. Web Frames validates substitutions before touching the device.

A state restarts the app, applies the theme, performs preparation and checks the
ready control before opening the screen deeplink and running screen actions.
The previous device theme is restored on completion, cancellation or error.
Preparation actions can choose an existing test account and enter test data;
app-specific offline fixtures can use launch arguments. iOS also receives
`WEBFRAMES_TEST_STATE`, `WEBFRAMES_TEST_ACCOUNT`, `WEBFRAMES_TEST_DATA` (JSON)
and `WEBFRAMES_TEST_THEME` as environment variables. Android receives the same
keys as string intent extras. Apps may consume this context in their own test
hooks; Web Frames does not create backend users or snapshot/restore app databases.
Preset values are plain document data: use test values, never passwords or tokens.
A failed preparation/readiness check keeps the saved screenshot.

Select exactly one image with a saved recipe and click **Start live preview**
(the radio waves icon). The recipe prepares its app/screen once, then the selected
frame shows incoming device images. Only one native runner is active across
boards. **Stop live preview**, changing selection, entering comment mode or
hiding/closing the window stops it. Refreshing screenshots stops preview first.
Live preview is view-only: it does not record actions, save a video, replace the
stored screenshot, add Undo entries or change comment evidence. Save/reopen
uses the last captured screenshot. Android protected windows remain blocked.
The preview ends after 15 minutes or if the app leaves the foreground. Agents
can refresh saved screenshots but cannot start a live preview through MCP.
`list_frames`/`get_frame` expose the state's name, theme, data keys and preparation
count, without account/data values, launch arguments or preparation text.

Legacy flow YAML and deeplink fields remain available for optional external
runners. Web Frames does not execute that YAML.
