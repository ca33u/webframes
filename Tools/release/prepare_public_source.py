#!/usr/bin/env python3
"""Prepare and verify a local source ZIP. Never commits, clones or uploads.

Use --ref RELEASE_TAG for a release, or --working-tree for an unpublished
preview including non-ignored new source files. No source checkout is created.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tarfile
from urllib.parse import unquote, urlsplit
import zipfile

ROOT_FILES = {'.gitignore', '.gitattributes', 'README.md', 'CHANGELOG.md',
              'CONTRIBUTING.md', 'SECURITY.md', 'LICENSE.md', 'Info.plist'}
ROOT_DIRS = {'.github', 'Tools', 'Examples', 'webframes', 'webframesTests',
             'webframesUITests', 'webframes.xcodeproj'}
PUBLIC_DOCS = {'docs/simulator-capture.md'}
PRIVATE_PARTS = {'.git', '.codex', '.claude', '.codex-bridge', '.webframes-cache',
                 'node_modules', 'runtime-dist', 'build', 'release', 'DerivedData',
                 'xcuserdata', '__pycache__', '.DS_Store'}
BINARY_SUFFIXES = {'.png', '.jpg', '.jpeg', '.webp', '.icns'}
PATH_PLACEHOLDERS = {'me', 'you', 'user', 'username', 'test', '<user>', '<username>'}
SECRET_PATTERNS = {
    'private key': re.compile(r'-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----'),
    'GitHub token': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})\b'),
    'OpenAI key': re.compile(r'\bsk-(?:proj-)?[A-Za-z0-9_-]{40,}\b'),
    'AWS access key': re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'Slack token': re.compile(r'\bxox[baprs]-[A-Za-z0-9-]{20,}\b'),
    'credential assignment': re.compile(r'''(?im)^\s*(?:export\s+)?(?:OPENAI_API_KEY|ANTHROPIC_API_KEY|GITHUB_TOKEN|GH_TOKEN|AWS_SECRET_ACCESS_KEY)\s*=\s*["']?[A-Za-z0-9_+/-]{20,}'''),
}


def git(root, *args):
    return subprocess.run(['git', '-C', str(root), *args], check=True,
                          capture_output=True).stdout


def public_path(name):
    p = PurePosixPath(name)
    if p.is_absolute() or '..' in p.parts or '\\' in name:
        raise ValueError('Unsafe archive path')
    # Tools/release contains public tooling; the root release directory is private.
    if p.parts[:2] == ('docs', 'internal'):
        return False
    if any(part in PRIVATE_PARTS - {'release'} for part in p.parts):
        return False
    if (p.parts[0] == 'release' or p.name.startswith('.env')
            or p.name in {'connection.json', '.npmrc', '.netrc'}
            or p.suffix in {'.pyc', '.p12', '.p8', '.key', '.pem', '.pfx', '.mobileprovision'}):
        return False
    if p.parts[0] == 'docs' and len(p.parts) > 2 and p.parts[1] == 'images':
        return True
    if name in PUBLIC_DOCS or (len(p.parts) == 1 and name in ROOT_FILES) or p.parts[0] in ROOT_DIRS:
        return True
    raise ValueError(f'Unreviewed public path: {name}')


def read_sources(root, ref=None):
    root = root.resolve()
    files = {}
    if ref:
        # git archive honors export-ignore and contains no private Git history.
        archive = git(root, 'archive', '--format=tar', ref)
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            for entry in tar:
                if entry.isdir() or not public_path(entry.name):
                    continue
                if not entry.isfile():
                    raise ValueError(f'Non-regular source: {entry.name}')
                files[entry.name] = (tar.extractfile(entry).read(), 0o755 if entry.mode & 0o111 else 0o644)
    else:
        names = git(root, 'ls-files', '--cached', '--others', '--exclude-standard', '-z').decode().split('\0')
        for name in sorted(set(filter(None, names))):
            if not public_path(name):
                continue
            path = root / name
            if not path.exists() and not path.is_symlink():
                continue  # Tracked deletion in a working-tree preview.
            if path.is_symlink() or root not in path.resolve().parents or not path.is_file():
                raise ValueError(f'Non-regular source: {name}')
            files[name] = (path.read_bytes(), 0o755 if path.stat().st_mode & 0o111 else 0o644)
    # Support older release tags whose README still lists private maintainer notes.
    if 'README.md' in files:
        body, mode = files['README.md']
        body = b''.join(line for line in body.splitlines(keepends=True)
                        if not line.startswith(b'| `docs/internal/` |'))
        files['README.md'] = body, mode
    return files


def inspect(files):
    findings = []
    required = {'README.md', 'LICENSE.md', 'SECURITY.md', 'CONTRIBUTING.md',
                '.github/workflows/ci.yml', 'webframes.xcodeproj/project.pbxproj',
                'webframes/webframesApp.swift', 'Tools/prepare_runtime.py'}
    for name in sorted(required - files.keys()):
        findings.append({'path': name, 'rule': 'missing required source'})
    for name, (data, _) in sorted(files.items()):
        if not public_path(name):
            findings.append({'path': name, 'rule': 'private path'})
        try:
            body = data.decode('utf-8')
        except UnicodeDecodeError:
            if PurePosixPath(name).suffix.lower() not in BINARY_SUFFIXES:
                findings.append({'path': name, 'rule': 'unreviewed binary'})
            continue
        for number, line in enumerate(body.splitlines(), 1):
            rules = [label for label, pattern in SECRET_PATTERNS.items() if pattern.search(line)]
            if any(user.lower() not in PATH_PLACEHOLDERS for user in re.findall(r'/(?:Users|home)/([^/\s"\']+)/', line)):
                rules.append('personal absolute path')
            if name.endswith('.md') and 'docs/internal/' in line:
                rules.append('internal documentation reference')
            findings.extend({'path': name, 'line': number, 'rule': rule} for rule in rules)
        if name.endswith('.md'):
            for target in re.findall(r'\[[^\]\n]+\]\(([^\s)]+)\)', body):
                url = urlsplit(target.strip('<>'))
                if url.scheme or url.netloc or not url.path:
                    continue
                # Resolve relative Markdown links inside the archive without extracting.
                parts = []
                for part in (PurePosixPath(name).parent / unquote(url.path)).parts:
                    if part == '..':
                        if parts:
                            parts.pop()
                        else:
                            parts = ['__outside_archive__']
                            break
                    elif part != '.':
                        parts.append(part)
                dest = '/'.join(parts)
                if url.path.startswith('/') or dest not in files and not any(p.startswith(dest + '/') for p in files):
                    findings.append({'path': name, 'rule': 'missing local Markdown target'})
    return findings


def write_archive(files, output, provenance):
    findings = inspect(files)
    if findings:
        # Locations/rules only: never echo credential contents in logs.
        raise ValueError(json.dumps({'findings': findings}, indent=2))
    if output.exists():
        raise ValueError('Output already exists; use a new directory')
    output.mkdir(parents=True)
    archive = output / 'public-source.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, (data, mode) in sorted(files.items()):
            entry = zipfile.ZipInfo(name, date_time=(2000, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | mode) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(entry, data)
    with zipfile.ZipFile(archive) as z:
        if z.testzip() is not None or set(z.namelist()) != set(files):
            raise ValueError('Archive verification failed')
        restored = {name: (z.read(name), (z.getinfo(name).external_attr >> 16) & 0o777) for name in z.namelist()}
    if restored != files or inspect(restored):
        raise ValueError('Archive contents failed verification')
    manifest = {'format': 1, 'published': False, **provenance,
                'archive': archive.name, 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
                'checks': {'archive_roundtrip': True, 'path_policy': True,
                           'credential_patterns': True, 'personal_paths': True, 'markdown_links': True},
                'files': {name: {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data), 'mode': oct(mode)}
                          for name, (data, mode) in sorted(files.items())}}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New local output directory')
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--ref', help='Existing release tag or commit; never HEAD by accident')
    source.add_argument('--working-tree', action='store_true', help='UNPUBLISHED preview of current files')
    args = parser.parse_args()
    root = Path(git(Path(__file__).resolve().parent, 'rev-parse', '--show-toplevel').decode().strip())
    commit = git(root, 'rev-parse', '--verify', (args.ref or 'HEAD') + '^{commit}').decode().strip()
    manifest = write_archive(read_sources(root, args.ref), args.output.resolve(),
                             {'source': 'git-ref' if args.ref else 'unpublished-working-tree',
                              'ref': args.ref, 'base_commit': commit})
    print(f"PASS: {len(manifest['files'])} source files; SHA-256 {manifest['sha256']}")
    print('Local archive only. Publication and a clean public commit require separate owner approval.')


if __name__ == '__main__':
    main()
