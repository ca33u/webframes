"""Release guard tests: every OS command is intercepted, no Apple requests."""
from contextlib import ExitStack
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import prepare_release

spec = importlib.util.spec_from_file_location('prepare_update', Path(__file__).parents[1] / 'updates/prepare_update.py')
update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update)


class ReleaseGuards(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'Web Frames.app'
        (self.app / 'Contents').mkdir(parents=True)
        self.info = dict(CFBundleIdentifier=update.ACCOUNT, SUFeedURL=update.FEED,
                         SUPublicEDKey='example-public-key', CFBundleShortVersionString='1.1.7',
                         CFBundleVersion='12', LSMinimumSystemVersion='15.0')
        self.write_info()
        self.output = self.root / 'output'
        self.marker = self.root / 'backup.txt'
        self.marker.write_text('public-key example-public-key\nbacked-up 2026-10-12\n')
        self.commands = []

    def write_info(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))

    def release_run(self, *args):
        args = [str(a) for a in args]
        self.commands.append(args)
        if args[:3] == ['codesign', '-d', '--entitlements']:
            return plistlib.dumps({}).decode()
        if args[0] == 'ditto' and '-c' in args:
            Path(args[-1]).write_bytes(b'fake archive')
        if args[:2] == ['hdiutil', 'create']:
            Path(args[-1]).write_bytes(b'fake disk image')
        if args == ['xcodebuild', '-version']:
            return 'Xcode test\n'
        return ''

    def release_stack(self, args, identity='Developer ID Application: Example', timestamp=False):
        stack = ExitStack()
        display = f'Authority={identity}\n' + ('Timestamp=example\n' if timestamp else '')
        stack.enter_context(patch.object(sys, 'argv', ['prepare_release.py', str(self.app), str(self.output), *args]))
        stack.enter_context(patch.object(prepare_release.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', display)))
        stack.enter_context(patch.object(prepare_release, 'run', side_effect=self.release_run))
        return stack

    def test_offline_disallows_notary_profile_before_any_command(self):
        with self.release_stack(['--offline', '--notary-profile', 'never-used']):
            with self.assertRaises(SystemExit) as raised:
                prepare_release.main()
        self.assertEqual(raised.exception.code, 2)
        self.assertFalse(self.commands)
        self.assertFalse(self.output.exists())

    def test_development_signature_is_rejected_even_for_offline_draft(self):
        with self.release_stack(['--offline'], identity='Apple Development: Example'):
            with self.assertRaisesRegex(ValueError, 'Apple Development'):
                prepare_release.main()
        self.assertFalse(self.output.exists())

    def test_distribution_mode_requires_secure_timestamp(self):
        with self.release_stack([]):
            with self.assertRaisesRegex(ValueError, 'timestamped'):
                prepare_release.main()
        self.assertFalse(self.output.exists())

    def test_offline_draft_never_timestamps_or_notarizes_and_is_labelled_local_only(self):
        with self.release_stack(['--offline']):
            prepare_release.main()
        metadata = json.loads((self.output / 'release.json').read_text())
        self.assertTrue(metadata['offlineDraft'])
        self.assertFalse(metadata['readyForDistribution'])
        self.assertFalse(metadata['notarized'])
        self.assertFalse(metadata['published'])
        self.assertEqual(metadata['requires'], ['secure timestamp', 'Apple notarization'])
        self.assertIn('Do not distribute', (self.output / 'Installer/Start Here.txt').read_text())
        self.assertTrue(all('LOCAL-ONLY-NOT-NOTARIZED' in name for name in metadata['artifacts']))
        signing = [c for c in self.commands if c[0] == 'codesign' and '--sign' in c]
        self.assertGreaterEqual(len(signing), 5)
        self.assertTrue(all('--timestamp=none' in c and '--timestamp' not in c for c in signing))
        self.assertFalse(any('notarytool' in c or 'stapler' in c or 'spctl' in c for c in self.commands))

    def test_debugger_entitlement_is_rejected_before_output_creation(self):
        with self.release_stack(['--offline']):
            original = self.release_run
            def debugger(*args):
                if [str(a) for a in args[:3]] == ['codesign', '-d', '--entitlements']:
                    return plistlib.dumps({'com.apple.security.get-task-allow': True}).decode()
                return original(*args)
            with patch.object(prepare_release, 'run', side_effect=debugger):
                with self.assertRaisesRegex(ValueError, 'debugger entitlement'):
                    prepare_release.main()
        self.assertFalse(self.output.exists())

    def test_key_backup_requires_one_exact_public_key_record(self):
        with patch.object(update, 'BACKUP_MARKER', self.marker):
            update.require_key_backup('example-public-key', False)
            for text in ['note example-public-key\n', 'public-key example-public-key-extra\n',
                         'public-key different\n', 'public-key example-public-key\npublic-key different\n']:
                self.marker.write_text(text)
                with self.assertRaises(ValueError):
                    update.require_key_backup('example-public-key', False)
            self.marker.unlink()
            with self.assertRaisesRegex(ValueError, 'No Sparkle key backup'):
                update.require_key_backup('example-public-key', False)

    def update_run(self, *args):
        args = [str(a) for a in args]
        self.commands.append(args)
        if Path(args[0]).name == 'generate_keys':
            return self.info['SUPublicEDKey']
        return ''

    def update_stack(self):
        stack = ExitStack()
        stack.enter_context(patch.object(sys, 'argv', ['prepare_update.py', str(self.app), str(self.output), '--sparkle-bin', str(self.root / 'bin')]))
        stack.enter_context(patch.object(update, 'BACKUP_MARKER', self.marker))
        stack.enter_context(patch.object(update, 'run', side_effect=self.update_run))
        return stack

    def test_equal_or_lower_build_is_rejected_without_touching_existing_feed(self):
        self.output.mkdir()
        for build in ['12', '12.0', '13']:
            feed = f'<rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><s:version>{build}</s:version></item></channel></rss>'
            (self.output / 'appcast.xml').write_text(feed)
            with self.update_stack():
                with self.assertRaisesRegex(ValueError, 'Increase CURRENT_PROJECT_VERSION'):
                    update.main()
            self.assertEqual((self.output / 'appcast.xml').read_text(), feed)
            self.assertEqual([p.name for p in self.output.iterdir()], ['appcast.xml'])

    def test_bad_signature_gatekeeper_or_missing_ticket_cannot_create_archive(self):
        for rejected in ['codesign', 'spctl', 'xcrun']:
            self.commands = []
            with self.update_stack():
                def refuse(*args):
                    if Path(str(args[0])).name == rejected:
                        raise subprocess.CalledProcessError(1, args)
                    return self.update_run(*args)
                with patch.object(update, 'run', side_effect=refuse):
                    with self.assertRaises(subprocess.CalledProcessError):
                        update.main()
            self.assertFalse(self.output.exists())
            self.assertFalse(any(Path(c[0]).name in {'ditto', 'generate_appcast'} for c in self.commands))

    def test_existing_update_archive_is_never_replaced(self):
        self.output.mkdir()
        archive = self.output / 'WebFrames-1.1.7-12.zip'
        archive.write_bytes(b'published bytes')
        with self.update_stack():
            with self.assertRaisesRegex(ValueError, 'Refusing to replace'):
                update.main()
        self.assertEqual(archive.read_bytes(), b'published bytes')
        self.assertFalse(any(Path(c[0]).name in {'ditto', 'generate_appcast'} for c in self.commands))


if __name__ == '__main__':
    unittest.main()
