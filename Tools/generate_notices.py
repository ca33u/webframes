#!/usr/bin/env python3
"""Regenerate the third-party notices bundled with Web Frames.

Writes webframes/ThirdPartyNotices.txt (full license and NOTICE texts) and
webframes/Credits.html (shown in About Web Frames). Run after
`prepare_runtime.py` installs the component-catalog dependencies; it is
called at the end of that script. Commit both outputs.
"""
import html
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
tools = root / 'Tools'
modules = tools / 'component-catalog/node_modules'
runtime = tools / 'runtime-dist/node-v22.23.2-darwin-arm64'
LICENSE_NAMES = ('LICENSE', 'LICENSE.md', 'LICENSE.txt', 'LICENCE', 'license', 'LICENSE-MIT')


def packages():
    for manifest in sorted(modules.glob('*/package.json')) + sorted(modules.glob('@*/*/package.json')):
        data = json.loads(manifest.read_text())
        folder = manifest.parent
        texts = []
        for name in LICENSE_NAMES + ('NOTICE', 'NOTICE.md', 'NOTICE.txt', 'ThirdPartyNoticeText.txt'):
            candidate = folder / name
            if candidate.is_file():
                texts.append((name, candidate.read_text(errors='replace').strip()))
        license_id = data.get('license') or (data.get('licenses') or [{}])[0].get('type', 'See license text')
        yield data['name'], data.get('version', ''), license_id, texts


def main():
    entries = []
    node_license = runtime / 'LICENSE'
    if node_license.is_file():
        entries.append(('Node.js', '22.23.2', 'MIT and bundled third-party licenses', [('LICENSE', node_license.read_text(errors='replace').strip())]))
    entries.append(('Sparkle', '2.10.0', 'MIT', [('LICENSE', (tools / 'licenses/Sparkle-LICENSE.txt').read_text().strip())]))
    entries.extend(packages())

    lines = ['Web Frames includes the following third-party software.', '']
    for name, version, license_id, texts in entries:
        lines += ['=' * 72, f'{name} {version}'.strip(), f'License: {license_id}', '']
        for label, text in texts:
            if len(texts) > 1:
                lines += [f'--- {label} ---']
            lines += [text, '']
    (root / 'webframes/ThirdPartyNotices.txt').write_text('\n'.join(lines) + '\n')

    items = ''.join(
        f'<li>{html.escape(name)} {html.escape(version)} — {html.escape(str(license_id))}</li>'
        for name, version, license_id, _ in entries)
    (root / 'webframes/Credits.html').write_text(
        '<!doctype html><html><head><meta charset="utf-8"><style>'
        'body{font:11px -apple-system,sans-serif;text-align:center}ul{list-style:none;padding:0;margin:6px 0}'
        '</style></head><body><p>Web Frames includes open-source software:</p>'
        f'<ul>{items}</ul><p>Full license texts: ThirdPartyNotices.txt in the app’s Resources folder.</p>'
        '</body></html>\n')
    print(f'Wrote notices for {len(entries)} components')


if __name__ == '__main__':
    main()
