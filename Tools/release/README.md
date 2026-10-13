# Building and distributing Web Frames

For a local, verified source archive for GitHub, see [Public source preparation](public_source.md).
It never commits or uploads; publication requires separate owner approval.

The installable build targets Apple Silicon and macOS 15.0+. Node 22.23.2,
the Codex connector, Comments MCP and the locked component preview dependencies
ship inside the app. Users do not need a terminal to connect Codex.
Codex itself is not redistributed: users install it and sign in separately.
Their own web projects may still require their own package managers/dependencies.
Component previews with a project PostCSS configuration use an existing Node
22.12+ installation for that project's native CSS plugins.

## Build

From the native project:

```sh
python3 Tools/prepare_runtime.py
xcodebuild -project webframes.xcodeproj -scheme webframes -configuration Release \
  -derivedDataPath build/Release \
  CODE_SIGN_STYLE=Manual \
  'CODE_SIGN_IDENTITY=Developer ID Application: Egor Sazanov (LW64FQXZCU)' \
  DEVELOPMENT_TEAM=LW64FQXZCU OTHER_CODE_SIGN_FLAGS=--timestamp build
```

`prepare_runtime.py` checks the official Node archive SHA-256 and installs the
locked helper packages with lifecycle scripts disabled. It regenerates exact
Xcode input/output file lists. Xcode script sandboxing remains enabled.
Do not commit runtime-dist or node_modules. Clean the build when changing
the dependency set so removed helper files do not remain in an old bundle.

Only the embedded Node executable receives `com.apple.security.cs.allow-jit`,
explicitly approved by the owner. Hardened Runtime and library validation stay
on; no unsigned-executable-memory or disable-library-validation entitlement is
added. Native addons are signed with the same identity as Node. The main app's
entitlements remain unchanged. Vite and all npm dependencies are unmodified.

## Check the installed layout without opening the app

Copy the built `.app` outside the source folder and run:

```sh
python3 Tools/release/smoke.py '/path/with spaces/Web Frames.app'
codesign --verify --deep --strict '/path/with spaces/Web Frames.app'
```

The smoke check exercises catalogue discovery, served HTML and transformed
TSX, authenticated connector health, rejection of unpaired requests and MCP
initialization. It never launches the native UI or submits an AI job.

## Prepare installer

```sh
python3 Tools/release/prepare_release.py '/path/Web Frames.app' \
  '/path/to/new/release-directory' --notary-profile 'YOUR_EXISTING_KEYCHAIN_PROFILE'
```

With a profile, the script submits the app to Apple, requires Accepted,
staples the ticket, checks Gatekeeper, signs Sparkle's nested helper services inside out, then builds/signs/notarizes/staples a
drag-to-Applications DMG. It also produces the ZIP and SHA-256 manifest.
Credentials stay in Keychain. The script never uploads to webframes.pro.

Without a profile it produces clearly named **NOT-NOTARIZED** draft artifacts.
Those are for preparation only and must not be promoted as a public release.
No Gatekeeper bypass instructions are included.

## Offline preflight (no Apple submissions or timestamps)

Use the existing pinned Sparkle package cache and prepared runtime dependencies.
Build a separate product from this checkout with `CODE_SIGN_STYLE=Manual`, the
Developer ID identity, `OTHER_CODE_SIGN_FLAGS=--timestamp=none` and
`WEBFRAMES_OFFLINE_SIGNING=YES`. Disable package updates/resolution and point
`-clonedSourcePackagesDirPath` at the existing cache; a missing cache must be
prepared separately. Release configuration alone does not select Developer ID:
an ordinary build/test can replace it with an Apple Development signature.
Recheck the identity of the exact product every time it is handed off.

```sh
python3 Tools/release/prepare_release.py '/path/Web Frames.app' \
  '/path/to/new/offline-directory' --offline
```

Offline mode rejects a notarization profile, signs nested Sparkle helpers and
the installer locally with `--timestamp=none`, and marks the ZIP/DMG, installer
instructions and manifest as **LOCAL-ONLY / NOT-NOTARIZED**. It never calls
notarytool, stapler or Gatekeeper assessment. This draft cannot be distributed:
rebuild/sign with secure timestamps and notarize only after owner approval.
The normal release path continues to require a timestamped Developer ID input.

```sh
python3 -m unittest discover -s Tools/release -p 'test_*.py'
```

These offline tests intercept all system commands and cover source export,
signing/draft labels, backup-key matching, increasing builds, signature and
notarization gates, and refusal to replace an existing update archive.

## Website and updates

After notarization, use `Tools/updates/prepare_update.py` on the stapled app
to create the Ed25519-signed Sparkle feed. Keep the private update key in
Keychain and make an owner-controlled backup before release.

Publish the verified installer and versioned update ZIP first. Publish the
appcast at `https://www.webframes.pro/updates/appcast.xml` after the ZIP is
available. Then switch the website download button to the verified DMG.
Check one real download/install and one update on another Mac before launch.

## Notarization credentials

For a new release machine, replace `YOUR_APPLE_ID_EMAIL` with the Apple
Developer account email and enter the app-specific password only in Terminal:

```sh
xcrun notarytool store-credentials "WebFrames-Notary" --apple-id "YOUR_APPLE_ID_EMAIL" --team-id LW64FQXZCU
```

Then run `prepare_release.py` with `--notary-profile WebFrames-Notary` into a
new output directory. Never upload a `NOT-NOTARIZED` installer to the public
download location. Apple acceptance and stapling must happen before
`prepare_update.py` signs a public update archive.

The owner performs the short final check: install/open, reopen a saved project,
check canvas shortcuts and pass Compare → Fix → review → Apply. Version 1.1.8
includes native iOS/Android capture, source build/install, recording, test states,
batch refresh and selected-frame live preview. See the [Simulator Capture guide](../../docs/simulator-capture.md)
for local SDK requirements. Packaging/check commands do not open the native UI.
