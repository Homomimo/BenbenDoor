"""Validate the unsigned device archive and package an IPA, retaining WidgetKit."""
import pathlib
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


app_info = read_info(app)
widget_info = read_info(widget)
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
    # A valid app binary alone is insufficient for a ControlWidget action.
    # Ensure intent extraction produced nonempty metadata in BOTH targets.
    metadata = bundle / 'Metadata.appintents'
    files = [p for p in metadata.rglob('*') if p.is_file()] if metadata.is_dir() else []
    assert files and sum(p.stat().st_size for p in files) > 0, f'Missing intent metadata: {bundle.name}'
    assert any(b'ControlDoorIntent' in p.read_bytes() for p in files), f'Control intent absent from metadata: {bundle.name}'

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
