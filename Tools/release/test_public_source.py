"""Offline distribution checks. No checkout, network, keychain or real secrets."""
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import prepare_public_source as public


def fixture():
    names = ['README.md', 'LICENSE.md', 'SECURITY.md', 'CONTRIBUTING.md',
             '.github/workflows/ci.yml', 'webframes.xcodeproj/project.pbxproj',
             'webframes/webframesApp.swift', 'Tools/prepare_runtime.py']
    return {name: (b'example\n', 0o644) for name in names}


class PublicSourceTests(unittest.TestCase):
    def test_private_paths_are_omitted_but_release_tools_are_kept(self):
        for path in ['docs/internal/notes.md', '.git/config', '.claude/config.json',
                     'release/a.zip', 'build/evidence.png', 'Tools/runtime-dist/node',
                     'Tools/component-catalog/node_modules/a.js', 'Examples/.env.local',
                     'Tools/connection.json', 'webframes/key.pem', 'webframes.xcodeproj/xcuserdata/a']:
            self.assertFalse(public.public_path(path), path)
        self.assertTrue(public.public_path('Tools/release/prepare_public_source.py'))
        self.assertTrue(public.public_path('docs/images/canvas.png'))

    def test_unsafe_or_unreviewed_paths_fail(self):
        for path in ['../README.md', '/etc/passwd', 'Tools/../../etc', 'Tools\\file', 'notes.txt']:
            with self.assertRaises(ValueError):
                public.public_path(path)

    def test_credential_findings_never_echo_values(self):
        secrets = ['ghp_' + 'a' * 36, 'sk-proj-' + 'a' * 48,
                   'AKIA' + 'A' * 16, 'xoxb-' + 'a' * 30,
                   '-----BEGIN ' + 'PRIVATE KEY-----',
                   'OPENAI_API_KEY=' + 'b' * 48]
        for secret in secrets:
            files = fixture()
            files['Tools/example.txt'] = (secret.encode(), 0o644)
            with tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'export'
                with self.assertRaises(ValueError) as raised:
                    public.write_archive(files, output, {})
                self.assertNotIn(secret, str(raised.exception))
                self.assertIn('Tools/example.txt', str(raised.exception))
                self.assertFalse(output.exists())

    def test_personal_paths_fail_but_fixture_placeholders_are_allowed(self):
        files = fixture()
        files['Tools/example.txt'] = (('/' + 'Users/alice/secret').encode(), 0o644)
        self.assertTrue(any(f['rule'] == 'personal absolute path' for f in public.inspect(files)))
        files['Tools/example.txt'] = (('/' + 'Users/me/example').encode(), 0o644)
        self.assertEqual(public.inspect(files), [])

    def test_secret_inside_broken_link_is_not_echoed(self):
        files = fixture()
        secret = 'ghp_' + 'a' * 36
        files['README.md'] = (f'[Example]({secret})'.encode(), 0o644)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError) as raised:
                public.write_archive(files, Path(directory) / 'export', {})
            self.assertNotIn(secret, str(raised.exception))

    def test_markdown_links_and_images_resolve_in_archive(self):
        files = fixture()
        files['Tools/README.md'] = (b'[License](../LICENSE.md)\n![Image](../docs/images/canvas.png)\n[Site](https://example.com)\n[Section](#local)\n', 0o644)
        files['docs/images/canvas.png'] = (b'\x89PNG\xff', 0o644)
        self.assertEqual(public.inspect(files), [])
        del files['docs/images/canvas.png']
        self.assertEqual(public.inspect(files)[0]['rule'], 'missing local Markdown target')

    def test_private_documentation_reference_is_blocked(self):
        files = fixture()
        files['README.md'] = (b'[Notes](docs/' + b'internal/notes.md)', 0o644)
        self.assertTrue(any(f['rule'] == 'internal documentation reference' for f in public.inspect(files)))

    def test_missing_core_source_and_unreviewed_binary_fail(self):
        files = fixture()
        del files['LICENSE.md']
        files['Tools/random.bin'] = (b'\xff\x00', 0o644)
        rules = {f['rule'] for f in public.inspect(files)}
        self.assertEqual(rules, {'missing required source', 'unreviewed binary'})

    def test_working_tree_includes_new_files_and_deletions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Tools').mkdir()
            (root / 'Tools/new.py').write_text('new')
            (root / 'README.md').write_text('hello\n| `docs/' + 'internal/` | private |\n')
            with patch.object(public, 'git', return_value=b'README.md\0Tools/new.py\0Tools/deleted.py\0'):
                files = public.read_sources(root)
            self.assertEqual(set(files), {'README.md', 'Tools/new.py'})
            self.assertEqual(files['README.md'][0], b'hello\n')

    def test_working_tree_rejects_symlink_file_and_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'source'
            root.mkdir()
            outside = Path(directory) / 'outside'
            outside.mkdir()
            (outside / 'file.py').write_text('outside')
            (root / 'Tools').symlink_to(outside, target_is_directory=True)
            with patch.object(public, 'git', return_value=b'Tools/file.py\0'):
                with self.assertRaisesRegex(ValueError, 'Non-regular source'):
                    public.read_sources(root)
            (root / 'Tools').unlink()
            (root / 'Tools').mkdir()
            (root / 'Tools/file.py').symlink_to(outside / 'file.py')
            with patch.object(public, 'git', return_value=b'Tools/file.py\0'):
                with self.assertRaisesRegex(ValueError, 'Non-regular source'):
                    public.read_sources(root)

    def test_release_archive_filters_private_material_without_extracting(self):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w') as archive:
            for name in ['README.md', 'Tools/release/check.py', 'docs/internal/notes.md']:
                entry = tarfile.TarInfo(name)
                entry.size = 5
                archive.addfile(entry, io.BytesIO(b'hello'))
        with patch.object(public, 'git', return_value=data.getvalue()) as git:
            files = public.read_sources(Path('/unused'), 'v1.0')
        git.assert_called_once_with(Path('/unused'), 'archive', '--format=tar', 'v1.0')
        self.assertEqual(set(files), {'README.md', 'Tools/release/check.py'})

    def test_release_symlink_is_rejected(self):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w') as archive:
            entry = tarfile.TarInfo('Tools/symlink')
            entry.type = tarfile.SYMTYPE
            entry.linkname = '/etc/passwd'
            archive.addfile(entry)
        with patch.object(public, 'git', return_value=data.getvalue()):
            with self.assertRaisesRegex(ValueError, 'Non-regular source'):
                public.read_sources(Path('/unused'), 'v1.0')

    def test_verified_zip_is_deterministic_preserves_modes_and_never_overwrites(self):
        files = fixture()
        files['Tools/prepare_runtime.py'] = (b'print(1)\n', 0o755)
        with tempfile.TemporaryDirectory() as directory:
            first, second = (Path(directory) / name for name in ('one', 'two'))
            a = public.write_archive(files, first, {'source': 'unpublished-working-tree'})
            b = public.write_archive(files, second, {'source': 'unpublished-working-tree'})
            self.assertEqual(a['sha256'], b['sha256'])
            self.assertFalse(a['published'])
            self.assertEqual(len(a['files']), len(files))
            self.assertEqual(json.loads((first / 'manifest.json').read_text()), a)
            with zipfile.ZipFile(first / a['archive']) as archive:
                self.assertEqual((archive.getinfo('Tools/prepare_runtime.py').external_attr >> 16) & 0o777, 0o755)
            with self.assertRaisesRegex(ValueError, 'already exists'):
                public.write_archive(files, first, {})


if __name__ == '__main__':
    unittest.main()
