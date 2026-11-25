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
        (metadata / 'extract.actionsdata').write_bytes(b'["UnlockDoorIntent","WidgetUnlockIntent"]')
        widget_metadata = self.widget / 'Metadata.appintents'
        widget_metadata.mkdir()
        (widget_metadata / 'extract.actionsdata').write_bytes(b'["WidgetUnlockIntent"]')
        diagnostic = self.root / 'build/ci'
        (diagnostic / 'ios-sdk.txt').write_text('26.0\n')
        (diagnostic / 'xcode-version.txt').write_text('Synthetic Xcode version\n')
        self.test_summary = json.dumps({'passedTests': 30, 'failedTests': 0, 'result': 'Passed'})

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

        def xcrun(arguments, **kwargs):
            if arguments[1] == 'xcresulttool':
                return self.test_summary
            self.assertEqual(arguments[1], 'lipo')
            return 'arm64\n'

        with patch('subprocess.check_output', side_effect=xcrun), patch('subprocess.run', side_effect=ditto), contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(self.script), run_name='__main__')

    def change_info(self, bundle, key, value):
        path = bundle / 'Info.plist'
        info = plistlib.loads(path.read_bytes())
        info[key] = value
        path.write_bytes(plistlib.dumps(info))

    def test_includes_widget_and_manifest(self):
        self.run_package()
        info = json.loads((self.root / 'dist/BuildInfo.json').read_text(encoding='utf-8'))
        self.assertEqual((info['appVersion'], info['build'], info['iosSdk']), ('1.4.0', '12', '26.0'))
        self.assertIn('30 tests', info['tests'])
        with zipfile.ZipFile(self.root / 'dist/BenbenDoor-unsigned.ipa') as archive:
            self.assertIn('Payload/BenbenDoor.app/PlugIns/BenbenDoorWidget.appex/BenbenDoorWidget', archive.namelist())

    def test_rejects_mismatched_widget_version(self):
        self.change_info(self.widget, 'CFBundleVersion', '11')
        with self.assertRaisesRegex(RuntimeError, 'version mismatch'):
            self.run_package()

    def test_rejects_unresolved_version_variables(self):
        for bundle in [self.app, self.widget]:
            self.change_info(bundle, 'CFBundleVersion', '$(CURRENT_PROJECT_VERSION)')
        with self.assertRaisesRegex(RuntimeError, 'Unresolved version'):
            self.run_package()

    def test_rejects_missing_intent_metadata_in_either_bundle(self):
        for bundle, replacement in [(self.app, b'["WidgetUnlockIntent"]'), (self.widget, b'[]')]:
            path = bundle / 'Metadata.appintents/extract.actionsdata'
            previous = path.read_bytes()
            with self.subTest(bundle=bundle.name):
                try:
                    path.write_bytes(replacement)
                    with self.assertRaisesRegex(RuntimeError, 'shortcut metadata missing'):
                        self.run_package()
                finally:
                    path.write_bytes(previous)

    def test_rejects_simulator_app(self):
        self.change_info(self.app, 'CFBundleSupportedPlatforms', ['iPhoneSimulator'])
        with self.assertRaisesRegex(RuntimeError, 'Simulator builds'):
            self.run_package()

    def test_rejects_simulator_widget_even_with_device_app(self):
        self.change_info(self.widget, 'CFBundleSupportedPlatforms', ['iPhoneSimulator'])
        with self.assertRaisesRegex(RuntimeError, 'Simulator builds'):
            self.run_package()

    def test_rejects_empty_missing_and_failing_test_runs(self):
        for result in ['{}', 'Invalid JSON',
                       '{"passedTests":0,"failedTests":0,"result":"Passed"}',
                       '{"passedTests":3,"failedTests":1,"result":"Failed"}',
                       '{"passedTests":3,"failedTests":0,"result":"Failed"}']:
            with self.subTest(result=result):
                self.test_summary = result
                with self.assertRaisesRegex(RuntimeError, 'XCTest'):
                    self.run_package()
                self.assertFalse((self.root / 'dist/BenbenDoor-unsigned.ipa').exists())

    def test_structured_summary_is_used_instead_of_log(self):
        (self.root / 'build/ci/tests.log').write_text('Executed 0 tests, with 0 failures')
        self.test_summary = json.dumps({'passedTests': 8, 'failedTests': 0, 'result': 'Passed'})
        self.run_package()
        info = json.loads((self.root / 'dist/BuildInfo.json').read_text(encoding='utf-8'))
        self.assertIn('8 tests', info['tests'])


if __name__ == '__main__':
    unittest.main()
