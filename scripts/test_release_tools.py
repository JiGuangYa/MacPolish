#!/usr/bin/env python3
"""Regression checks for release preservation and corruption detection."""
import json
import os
from pathlib import Path
import tempfile
import unittest

from package_release import publish_outputs, validate_versions
from verify_release import ARCHIVES, OUTPUTS, sha256, verify_checksums


class ReleaseToolsTests(unittest.TestCase):
    def test_invalid_version_inputs_are_rejected(self):
        for version in ('', '1', '1.2', '1.0.0-beta', '01.2.3', '1.2.3\n', '<string>1.0.0'):
            with self.subTest(version=version), self.assertRaises(ValueError):
                validate_versions(version, '1')
        for build in ('', '0', '-1', '01', '1.0', '1\n'):
            with self.subTest(build=build), self.assertRaises(ValueError):
                validate_versions('1.0.0', build)
        validate_versions('2.10.3', '42')

    def make_outputs(self, directory, marker):
        directory.mkdir()
        for name in OUTPUTS:
            path = directory / name
            if name.endswith('.app'):
                path.mkdir()
                path = path / 'executable'
            path.write_text(marker)

    def assert_outputs(self, directory, marker):
        for name in OUTPUTS:
            path = directory / name
            if name.endswith('.app'):
                path = path / 'executable'
            self.assertEqual(path.read_text(), marker, name)

    def test_failed_publication_restores_every_previous_artifact(self):
        # Exercise a failure before and after moving each existing artifact,
        # including the nonempty .app directory and the last checksum file.
        for failure_at in range(1, len(OUTPUTS) * 2 + 1):
            with self.subTest(failure_at=failure_at), tempfile.TemporaryDirectory() as root:
                root = Path(root)
                staging, destination = root / 'staging', root / 'dist'
                self.make_outputs(staging, 'new')
                self.make_outputs(destination, 'old')
                (destination / 'user-notes.txt').write_text('keep')
                calls = 0

                def failing_replace(source, target):
                    nonlocal calls
                    calls += 1
                    if calls == failure_at:
                        raise OSError('simulated interrupted publication')
                    os.replace(source, target)

                with self.assertRaises(OSError):
                    publish_outputs(staging, destination, replace=failing_replace)
                self.assert_outputs(destination, 'old')
                self.assertEqual((destination / 'user-notes.txt').read_text(), 'keep')
                self.assertEqual(list(root.glob('MacPolish-previous-release-*')), [])

    def test_success_replaces_only_owned_outputs(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            staging, destination = root / 'staging', root / 'dist'
            self.make_outputs(staging, 'new')
            self.make_outputs(destination, 'old')
            (destination / 'user-notes.txt').write_text('keep')
            publish_outputs(staging, destination)
            self.assert_outputs(destination, 'new')
            self.assertEqual((destination / 'user-notes.txt').read_text(), 'keep')

    def test_truncated_and_modified_archives_are_rejected(self):
        for changed_bytes in (b'truncated', b'changed archive'):
            with self.subTest(changed_bytes=changed_bytes), tempfile.TemporaryDirectory() as root:
                root = Path(root)
                for name in ARCHIVES:
                    (root / name).write_bytes(b'originalarchive')
                manifest = {'archives': {name: {'sha256': sha256(root / name), 'bytes': (root / name).stat().st_size} for name in ARCHIVES}}
                (root / 'release-manifest.json').write_text(json.dumps(manifest))
                names = (*ARCHIVES, 'release-manifest.json')
                (root / 'SHA256SUMS').write_text(''.join(f'{sha256(root / name)}  {name}\n' for name in names))
                verify_checksums(root, manifest)
                (root / 'MacPolish.dmg').write_bytes(changed_bytes)
                with self.assertRaises(ValueError):
                    verify_checksums(root, manifest)


if __name__ == '__main__':
    unittest.main()
