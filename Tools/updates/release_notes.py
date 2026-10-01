#!/usr/bin/env python3
"""Render one CHANGELOG.md section as the Sparkle release-notes page.

    python3 Tools/updates/release_notes.py 1.0.2 5 > WebFrames-1.0.2-5.html

The section is found by its heading, `## <version> (<build>)`. Supports the
subset CHANGELOG.md uses: `###` headings, `- ` bullets with indented
continuation lines, **bold** and `code`.
"""
import datetime
import html
import re
import sys
from pathlib import Path

CHANGELOG = Path(__file__).resolve().parents[2] / 'CHANGELOG.md'
STYLE = ('body{font:16px/1.6 -apple-system,BlinkMacSystemFont,sans-serif;background:#181818;color:#eee;'
         'max-width:680px;padding:32px;margin:auto}h1{color:#ff683b}h2{font-size:17px;margin-top:28px}'
         'li{margin:10px 0}a{color:#ff906f}code{font:14px ui-monospace,monospace}')


def section(text, version, build):
    heading = re.compile(rf'^## {re.escape(version)} \({re.escape(build)}\)(?:\s+—\s+(.*))?\s*$', re.M)
    match = heading.search(text)
    if not match:
        raise SystemExit(f'CHANGELOG.md has no "## {version} ({build})" section. Rename "Unreleased" before releasing.')
    rest = text[match.end():]
    end = re.search(r'^## ', rest, re.M)
    return match.group(1) or '', rest[:end.start()] if end else rest


def inline(value):
    value = html.escape(value, quote=False)
    value = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', value)
    return re.sub(r'`(.+?)`', r'<code>\1</code>', value)


def render(body):
    out, items, current = [], [], None
    def flush():
        nonlocal items
        if items:
            out.append('<ul>' + ''.join(f'<li>{inline(i)}</li>' for i in items) + '</ul>')
            items = []
    for line in body.splitlines():
        if line.startswith('### '):
            flush(); out.append(f'<h2>{inline(line[4:].strip())}</h2>')
        elif line.startswith('- '):
            items.append(line[2:].strip())
        elif line.startswith('  ') and items:
            items[-1] += ' ' + line.strip()
        elif line.strip():
            flush(); out.append(f'<p>{inline(line.strip())}</p>')
    flush()
    return '\n'.join(out)


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    version, build = sys.argv[1], sys.argv[2]
    date, body = section(CHANGELOG.read_text(), version, build)
    date = date or datetime.date.today().isoformat()
    print(f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
          f'<title>Web Frames {html.escape(version)}</title><style>{STYLE}</style></head><body>'
          f'<h1>Web Frames {html.escape(version)}</h1><p>Build {html.escape(build)} · {html.escape(date)} · Apple Silicon · macOS 15 or later</p>'
          f'{render(body)}</body></html>')


if __name__ == '__main__':
    main()
