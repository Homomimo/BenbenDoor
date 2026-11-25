"""Validate the unsigned device archive and package an IPA, retaining WidgetKit."""
import pathlib
import json
import os
import plistlib
import subprocess
import tempfile
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent
app = root / 'build/ci/BenbenDoor.xcarchive/Products/Applications/BenbenDoor.app'
widget = app / 'PlugIns/BenbenDoorWidget.appex'


def read_info(bundle):
    with (bundle / 'Info.plist').open('rb') as stream:
        return plistlib.load(stream)


class PackagingError(RuntimeError):
    """An archive or test result did not meet the release requirements."""


def require(condition, message):
    if not condition:
        raise PackagingError(message)


app_info = read_info(app)
widget_info = read_info(widget)
for field in ['CFBundleShortVersionString', 'CFBundleVersion']:
    require(app_info[field] == widget_info[field], f'App/widget version mismatch: {field}')
    require('$(' not in app_info[field], f'Unresolved version setting: {field}')
require((app / 'Assets.car').is_file(), 'Compiled asset catalog missing')
primary_icon = app_info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {})
require(primary_icon.get('CFBundleIconName') == 'AppIcon', 'App icon metadata missing')
require(widget_info['CFBundleIdentifier'].startswith(app_info['CFBundleIdentifier'] + '.'),
        'Widget bundle identifier must use the app identifier prefix')
require(widget_info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension',
        'WidgetKit extension declaration missing')
for bundle, info in [(app, app_info), (widget, widget_info)]:
    require(info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'],
            f'Simulator builds cannot be installed on iPhone: {bundle.name}')
    executable = bundle / info['CFBundleExecutable']
    require(executable.is_file(), f'Bundle executable missing: {executable}')
    archs = subprocess.check_output(['xcrun', 'lipo', '-archs', str(executable)], text=True).split()
    require('arm64' in archs, f'arm64 executable missing: {bundle.name}, architectures: {archs}')
    require(not (bundle / 'embedded.mobileprovision').exists(), f'Expected an unsigned bundle: {bundle.name}')

for bundle, intents in [(app, ['UnlockDoorIntent', 'WidgetUnlockIntent']), (widget, ['WidgetUnlockIntent'])]:
    metadata = [path.read_bytes() for path in (bundle / 'Metadata.appintents').rglob('*') if path.is_file()]
    for intent in intents:
        require(any(intent.encode() in contents for contents in metadata),
                f'Unlock shortcut metadata missing: {bundle.name}, {intent}')

# Read the result bundle instead of parsing human-readable xcodebuild output.
result_bundle = root / 'build/ci/ProtocolTests.xcresult'
try:
    summary = json.loads(subprocess.check_output(
        ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result_bundle)], text=True
    ))
except (subprocess.CalledProcessError, ValueError) as error:
    raise PackagingError('Could not read XCTest results') from error
require(isinstance(summary, dict), 'Invalid XCTest summary')
passed = summary.get('passedTests')
failed = summary.get('failedTests')
require(type(passed) is int and passed > 0 and type(failed) is int and failed == 0
        and summary.get('result') == 'Passed', 'Missing, empty or failing XCTest results')

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
    require(archive.testzip() is None, 'Corrupt IPA contents')
    names = archive.namelist()
    require('Payload/BenbenDoor.app/BenbenDoor' in names, 'App executable missing from IPA')
    require('Payload/BenbenDoor.app/PlugIns/BenbenDoorWidget.appex/BenbenDoorWidget' in names,
            'Widget executable missing from IPA')
    require(not any(name.endswith('.private.json') for name in names), 'Private configuration found in IPA')
print('Unsigned device IPA (app + widget):', out)

build_info = {
    'appVersion': app_info['CFBundleShortVersionString'],
    'build': app_info['CFBundleVersion'],
    'iosSdk': (root / 'build/ci/ios-sdk.txt').read_text().strip(),
    'xcode': (root / 'build/ci/xcode-version.txt').read_text().strip(),
    'commit': os.environ.get('GITHUB_SHA', 'local'),
    'tests': f'Passed {passed} tests, with {failed} failures',
    'deviceValidation': 'Not performed by this build workflow',
}
(out.parent / 'BuildInfo.json').write_text(json.dumps(build_info, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
