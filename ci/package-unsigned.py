"""Validate the unsigned device archive and package an IPA, retaining WidgetKit."""
import pathlib
import json
import os
import plistlib
import re
import subprocess
import tempfile
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent
app = root / 'build/ci/BenbenDoor.xcarchive/Products/Applications/BenbenDoor.app'
widget = app / 'PlugIns/BenbenDoorWidget.appex'


def read_info(bundle):
    with (bundle / 'Info.plist').open('rb') as stream:
        return plistlib.load(stream)


app_info = read_info(app)
widget_info = read_info(widget)
for field in ['CFBundleShortVersionString', 'CFBundleVersion']:
    assert app_info[field] == widget_info[field], f'App/widget version mismatch: {field}'
    assert '$(' not in app_info[field], f'Unresolved version setting: {field}'
assert (app / 'Assets.car').is_file(), 'Compiled asset catalog missing'
assert app_info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {}).get('CFBundleIconName') == 'AppIcon', 'App icon metadata missing'
assert widget_info['CFBundleIdentifier'].startswith(app_info['CFBundleIdentifier'] + '.')
assert widget_info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension'
assert 'iPhoneOS' in app_info['CFBundleSupportedPlatforms'], 'Simulator builds cannot be installed on iPhone'
for bundle, info in [(app, app_info), (widget, widget_info)]:
    executable = bundle / info['CFBundleExecutable']
    assert executable.is_file(), executable
    archs = subprocess.check_output(['xcrun', 'lipo', '-archs', str(executable)], text=True).split()
    assert 'arm64' in archs, (bundle.name, archs)
    assert not (bundle / 'embedded.mobileprovision').exists(), 'Expected an unsigned archive'

# The retained shortcut belongs to the main app only. The timeline widget no
# longer declares an App Intent and does not require extracted intent metadata.
metadata = app / 'Metadata.appintents'
files = [p for p in metadata.rglob('*') if p.is_file()] if metadata.is_dir() else []
assert files and any(b'UnlockDoorIntent' in p.read_bytes() for p in files), 'Main app unlock shortcut metadata missing'

out = root / 'dist/BenbenDoor-unsigned.ipa'
out.parent.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='benben-ipa-') as temporary:
    staging = pathlib.Path(temporary)
    payload = staging / 'Payload'
    payload.mkdir()
    subprocess.run(['/usr/bin/ditto', str(app), str(payload / app.name)], check=True)
    out.unlink(missing_ok=True)
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(payload), str(out)], check=True)

with zipfile.ZipFile(out) as archive:
    assert archive.testzip() is None
    assert 'Payload/BenbenDoor.app/BenbenDoor' in archive.namelist()
    assert 'Payload/BenbenDoor.app/PlugIns/BenbenDoorWidget.appex/BenbenDoorWidget' in archive.namelist()
    assert not any(name.endswith('.private.json') for name in archive.namelist())
print('Unsigned device IPA (app + widget):', out)

tests_log = (root / 'build/ci/tests.log').read_text(encoding='utf-8', errors='replace')
summaries = re.findall(r'Executed \d+ tests?, with \d+ failures?[^\n]*', tests_log)
build_info = {
    'appVersion': app_info['CFBundleShortVersionString'],
    'build': app_info['CFBundleVersion'],
    'iosSdk': (root / 'build/ci/ios-sdk.txt').read_text().strip(),
    'xcode': (root / 'build/ci/xcode-version.txt').read_text().strip(),
    'commit': os.environ.get('GITHUB_SHA', 'local'),
    'tests': summaries[-1] if summaries else 'xcodebuild test succeeded; inspect ProtocolTests.xcresult for details',
    'deviceValidation': 'Not performed by this build workflow',
}
(out.parent / 'BuildInfo.json').write_text(json.dumps(build_info, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
