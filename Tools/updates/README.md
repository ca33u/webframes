# Web Frames updates

Sparkle 2.10.0 is pinned through Swift Package Manager. AppUpdater starts once
for Release builds and provides Web Frames → Check for Updates….
Debug builds deliberately do not start Sparkle or replace the app from Xcode.
Sparkle asks the user whether to check automatically; installation is not forced.

Production feed: https://www.webframes.pro/updates/appcast.xml
Version 1.0.1 (build 4) was published on 23 September 2026. The site contains
the signed archive and appcast under public/updates, with revalidation for the feed.
Preserve published versioned files and never replace this feed with an empty one.

The Ed25519 private key stays in macOS Keychain under account
`app.essazanov.webframes`. Only the public key belongs in Info.plist.
Keep a secure backup of the private key before distributing the first release;
never add it to source control or the website. Use Sparkle generate_keys for
backup/restore on the release machine. Do not regenerate the key for each version.

## Back up the signing key

Losing the private key means no installed copy can ever be updated again.
`prepare_update.py` refuses to publish until a backup is recorded for the
current key. Do this once per key, on the release machine:

```sh
SPARKLE_BIN='/path/to/SourcePackages/artifacts/sparkle/Sparkle/bin'
# 1. Export the private key to a temporary file (Keychain will ask for permission).
"$SPARKLE_BIN/generate_keys" --account app.essazanov.webframes -x "$HOME/Desktop/webframes-sparkle.private"
# 2. Move that file into the password manager (as a secure note/attachment)
#    and/or an offline drive. Then delete the temporary copy:
rm "$HOME/Desktop/webframes-sparkle.private"
# 3. Record the backup. The marker holds only the PUBLIC key and a date.
mkdir -p "$HOME/Library/Application Support/Web Frames"
printf 'public-key %s\nbacked-up %s\nwhere <password manager entry / drive label>\n' \
  "$("$SPARKLE_BIN/generate_keys" --account app.essazanov.webframes -p)" "$(date +%F)" \
  > "$HOME/Library/Application Support/Web Frames/sparkle-key-backup.txt"
```

Restore on a new machine: `generate_keys --account app.essazanov.webframes -i <file>`.
The marker is per machine and is never committed; `--skip-backup-check` exists
for emergencies only.

## Publish a version

1. Increase CURRENT_PROJECT_VERSION for each release. Set MARKETING_VERSION.
2. Archive the Release scheme, export with Developer ID signing, notarize it
   with Apple and staple the ticket. Preserve Sparkle.framework and its helpers.
3. Use an archive directory retaining previously published releases and appcast.
   Run (paths are examples to replace with the actual exported app and artifact bin):

```sh
python3 Tools/updates/prepare_update.py '/path/to/Web Frames.app' '/path/to/updates' --sparkle-bin '/path/to/SourcePackages/artifacts/sparkle/Sparkle/bin'
```

The command verifies the bundle, key match, increasing build number, code
signature and notarization. It creates a ZIP preserving symlinks and uses
Sparkle to generate archive signatures. It never launches the app or publishes.
Stage the generated ZIPs and appcast in the website public/updates directory.
Deploy immutable versioned ZIPs first and appcast.xml last (or atomically).
Keep older ZIP URLs available. Exclude old_updates/ from deployment.

## Release acceptance (user performs)

- Install the previous notarized Release in Applications; open a saved project.
- Publish a higher build and use Check for Updates…. Verify version/notes.
- Install and relaunch; verify project files and settings are preserved.
- Repeat a check: no newer release should be offered.
- Cancel an offered update: the current app should remain usable.
- Check offline: show a network error without changing the installed app.
- In an isolated test feed, tamper with an archive: installation must be rejected.

Production build 4 is published; downloaded ZIP signature, checksum and feed
were verified. A real install/update/relaunch cycle between two releases remains
a manual release check. Official setup: https://sparkle-project.org/documentation/

## Version and release notes

1. `python3 Tools/release/bump_version.py <version> <build>` sets both values in
   all six build configurations and refuses a build number that does not
   increase.
2. Rename `## Unreleased` in `CHANGELOG.md` to `## <version> (<build>) — <date>`
   and keep only user-facing entries.
3. `prepare_update.py` renders that section into `WebFrames-<version>-<build>.html`
   next to the ZIP (preview with `python3 Tools/updates/release_notes.py <version> <build>`);
   `generate_appcast` links it as the Sparkle release notes and Help › Release
   Notes opens the same page.

`prepare_release.py` records the Xcode build, toolchain and SDK in `release.json`.
`prepare_runtime.py` requires Python 3.12+ for safe tar extraction.
