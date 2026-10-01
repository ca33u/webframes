# Building and distributing Web Frames

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
check canvas shortcuts and pass Compare → Fix → review → Apply. Catalogue
preview refinements remain follow-up work. iOS, Android and PDF are not part
of this release. No native UI is opened by the packaging/check commands.
