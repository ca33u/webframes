#!/usr/bin/env python3
"""Stage a Developer ID release; notarize only with a named Keychain profile.
Never launches the app, uploads to the website or changes Gatekeeper settings.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

def run(*args):
    return subprocess.run([str(a) for a in args], check=True, text=True, capture_output=True).stdout

def notarize(artifact, profile):
    result = json.loads(run('xcrun', 'notarytool', 'submit', artifact, '--keychain-profile', profile, '--wait', '--output-format', 'json'))
    artifact.with_suffix(artifact.suffix + '.notary.json').write_text(json.dumps(result, indent=2) + '\n')
    if result.get('status') != 'Accepted':
        raise RuntimeError('Apple did not accept this artifact. Inspect the saved submission ID with notarytool log.')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path, help='A new, empty release directory')
    parser.add_argument('--notary-profile', help='Existing notarytool Keychain profile; never pass a password')
    args = parser.parse_args()
    app = args.app.resolve()
    output = args.output.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'app.essazanov.webframes': raise ValueError('Not a Web Frames build')
    result = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], text=True, capture_output=True, check=True)
    if 'Authority=Developer ID Application:' not in result.stderr or 'Timestamp=' not in result.stderr:
        raise ValueError('Requires a timestamped Developer ID application signature')
    entitlements = plistlib.loads(run('codesign', '-d', '--entitlements', '-', '--xml', app).encode())
    if entitlements.get('com.apple.security.get-task-allow'):
        raise ValueError('Release contains debugger entitlement; set CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO')
    run('codesign', '--verify', '--deep', '--strict', app)
    output.mkdir(parents=True, exist_ok=False)
    stage = output / 'Installer'
    stage.mkdir()
    installed = stage / 'Web Frames.app'
    run('ditto', app, installed)
    identity = next(line.split('=', 1)[1] for line in result.stderr.splitlines() if line.startswith('Authority=Developer ID Application:'))
    # Xcode signs the framework wrapper; Sparkle's nested SPM helpers may still
    # be ad-hoc. Sign from the inside out before the final application seal.
    framework = installed / 'Contents/Frameworks/Sparkle.framework'
    version = framework / 'Versions/B'
    for code in [version / 'Autoupdate', version / 'Updater.app',
                 *sorted((version / 'XPCServices').glob('*.xpc')), framework, installed]:
        run('codesign', '--force', '--sign', identity, '--timestamp', '--options', 'runtime',
            '--preserve-metadata=identifier,entitlements', code)
    run('codesign', '--verify', '--deep', '--strict', installed)
    (stage / 'Applications').symlink_to('/Applications')
    (stage / 'Start Here.txt').write_text(f'''Web Frames — Apple Silicon, macOS {info['LSMinimumSystemVersion']} or later

1. Drag Web Frames into Applications.
2. Open it and create a project, or open an existing .webframes document.
3. Add a local web project, website or image with the + button.

Node and component-preview helpers are included. Your own web project may
still need its normal dependencies and package manager to run its dev server.
Component previews using project PostCSS plugins need a local Node 22.12+
installation. Some components require sample props or a preview wrapper.
Server actions are disabled in isolated component previews.

For Compare and Fix with Codex: install Codex, sign in, then choose
Settings > Codex > Connect Codex in Web Frames.
Your account needs access to GPT-6 Astra; account usage limits apply.

Comments stay open until reviewed. Agents can change comment status only when
you enable Allow agents to resolve comments in Settings. Source changes require Apply.
Check for Updates is in the Web Frames menu.
''')
    name = f"WebFrames-{info['CFBundleShortVersionString']}-{info['CFBundleVersion']}-arm64"
    status = 'notarized' if args.notary_profile else 'NOT-NOTARIZED'
    archive = output / (name + '-' + status + '.zip')
    if args.notary_profile:
        submission = output / 'NotarizationSubmission.zip'
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', installed, submission)
        notarize(submission, args.notary_profile)
        run('xcrun', 'stapler', 'staple', installed)
        run('xcrun', 'stapler', 'validate', installed)
        run('spctl', '--assess', '--type', 'execute', installed)
        submission.unlink()
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', installed, archive)
    dmg = output / (name + '-' + status + '.dmg')
    run('hdiutil', 'create', '-volname', 'Web Frames', '-srcfolder', stage, '-format', 'UDZO', dmg)
    # Use the same verified team identity as the application.
    run('codesign', '--sign', identity, '--timestamp', dmg)
    if args.notary_profile:
        notarize(dmg, args.notary_profile)
        run('xcrun', 'stapler', 'staple', dmg)
        run('xcrun', 'stapler', 'validate', dmg)
    run('hdiutil', 'verify', dmg)
    metadata = {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
                'architecture': 'arm64', 'minimumMacOS': info['LSMinimumSystemVersion'],
                'notarized': bool(args.notary_profile), 'published': False,
                'xcode': info.get('DTXcodeBuild', ''), 'toolchain': run('xcodebuild', '-version').replace('\n', ' · '),
                'sdk': info.get('DTSDKName', ''),
                'artifacts': {p.name: {'sha256': hashlib.sha256(p.read_bytes()).hexdigest(), 'bytes': p.stat().st_size} for p in (archive, dmg)}}
    (output / 'release.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print('Prepared installer: ' + str(dmg))
    print('Ready for public distribution.' if args.notary_profile else 'NOT READY FOR PUBLIC DISTRIBUTION: Apple notarization is still required.')

if __name__ == '__main__': main()
