"""Exercise packaging policy with synthetic bundles; no Xcode/signing required."""
import contextlib
import io
import json
from pathlib import Path
import plistlib
import runpy
import shutil
import tempfile
import unittest
from unittest.mock import patch
import zipfile


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='benben-package-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.script = self.root / 'ci/package-unsigned.py'
        self.script.parent.mkdir()
        shutil.copyfile(Path(__file__).with_name('package-unsigned.py'), self.script)
        self.app = self.root / 'build/ci/BenbenDoor.xcarchive/Products/Applications/BenbenDoor.app'
        self.widget = self.app / 'PlugIns/BenbenDoorWidget.appex'
        self.widget.mkdir(parents=True)
        for bundle, executable, identifier in [(self.app, 'BenbenDoor', 'com.example.benbendoor'),
                                                 (self.widget, 'BenbenDoorWidget', 'com.example.benbendoor.widget')]:
            info = {'CFBundleExecutable': executable, 'CFBundleIdentifier': identifier,
                    'CFBundleVersion': '12', 'CFBundleShortVersionString': '1.4.0',
                    'CFBundleSupportedPlatforms': ['iPhoneOS']}
            if bundle == self.app:
                info['CFBundleIcons'] = {'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon'}}
            else:
                info['NSExtension'] = {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'}
            (bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
            (bundle / executable).write_bytes(b'synthetic-arm64-placeholder')
        (self.app / 'Assets.car').write_bytes(b'synthetic-assets')
        metadata = self.app / 'Metadata.appintents'
        metadata.mkdir()
        (metadata / 'extract.actionsdata').write_bytes(b'{"intent":"UnlockDoorIntent"}')
        diagnostic = self.root / 'build/ci'
        (diagnostic / 'ios-sdk.txt').write_text('26.0\n')
        (diagnostic / 'xcode-version.txt').write_text('Synthetic Xcode version\n')
        (diagnostic / 'tests.log').write_text('Executed 30 tests, with 0 failures (0 unexpected)\n')

    def run_package(self):
        def ditto(arguments, **kwargs):
            if '-c' in arguments:
                payload, output = map(Path, arguments[-2:])
                with zipfile.ZipFile(output, 'w') as archive:
                    for path in payload.rglob('*'):
                        if path.is_file():
                            archive.write(path, path.relative_to(payload.parent).as_posix())
            else:
                shutil.copytree(arguments[-2], arguments[-1])

        with patch('subprocess.check_output', return_value='arm64\n'), patch('subprocess.run', side_effect=ditto), contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(self.script), run_name='__main__')

    def change_info(self, bundle, key, value):
        path = bundle / 'Info.plist'
        info = plistlib.loads(path.read_bytes())
        info[key] = value
        path.write_bytes(plistlib.dumps(info))

    def test_includes_widget_and_manifest_without_widget_intent_metadata(self):
        self.run_package()
        info = json.loads((self.root / 'dist/BuildInfo.json').read_text(encoding='utf-8'))
        self.assertEqual((info['appVersion'], info['build'], info['iosSdk']), ('1.4.0', '12', '26.0'))
        self.assertIn('30 tests', info['tests'])
        with zipfile.ZipFile(self.root / 'dist/BenbenDoor-unsigned.ipa') as archive:
            self.assertIn('Payload/BenbenDoor.app/PlugIns/BenbenDoorWidget.appex/BenbenDoorWidget', archive.namelist())

    def test_rejects_mismatched_widget_version(self):
        self.change_info(self.widget, 'CFBundleVersion', '11')
        with self.assertRaisesRegex(AssertionError, 'version mismatch'):
            self.run_package()

    def test_rejects_unresolved_version_variables(self):
        for bundle in [self.app, self.widget]:
            self.change_info(bundle, 'CFBundleVersion', '$(CURRENT_PROJECT_VERSION)')
        with self.assertRaisesRegex(AssertionError, 'Unresolved version'):
            self.run_package()

    def test_rejects_missing_background_shortcut_metadata(self):
        (self.app / 'Metadata.appintents/extract.actionsdata').write_bytes(b'{}')
        with self.assertRaisesRegex(AssertionError, 'shortcut metadata missing'):
            self.run_package()

    def test_rejects_simulator_app(self):
        self.change_info(self.app, 'CFBundleSupportedPlatforms', ['iPhoneSimulator'])
        with self.assertRaisesRegex(AssertionError, 'Simulator builds'):
            self.run_package()


if __name__ == '__main__':
    unittest.main()
