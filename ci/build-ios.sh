#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build/ci dist
# Compile the native Liquid Glass branch with an iOS 26 SDK or newer.
DEVELOPER_DIR="$(python3 - <<'PY'
import os, pathlib, subprocess
candidates = []
for app in pathlib.Path('/Applications').glob('Xcode*.app'):
    if 'beta' in app.name.lower():
        continue
    developer = str(app / 'Contents/Developer')
    env = dict(os.environ, DEVELOPER_DIR=developer)
    try:
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], env=env, text=True, stderr=subprocess.DEVNULL).strip()
        version = tuple(int(part) for part in sdk.split('.'))
    except (subprocess.CalledProcessError, ValueError):
        continue
    if version >= (26, 0):
        candidates.append((version, developer))
if not candidates:
    raise SystemExit('This UI requires an installed stable Xcode with iOS SDK 26+. Check the GitHub runner image.')
print(max(candidates)[1])
PY
)"
export DEVELOPER_DIR
xcodebuild -version | tee build/ci/xcode-version.txt
xcodebuild -list -project BenbenDoor.xcodeproj | tee build/ci/project.log
plutil -lint App/Info.plist Widget/Info.plist BenbenDoor.xcodeproj/project.pbxproj

# Select an available iPhone instead of assuming a particular simulator name.
xcrun simctl list devices available --json > build/ci/simulators.json
SIMULATOR_ID="$(python3 - <<'PY'
import json
with open('build/ci/simulators.json') as stream:
    runtimes = json.load(stream)['devices']
for runtime, devices in sorted(runtimes.items(), reverse=True):
    if '.iOS-' not in runtime:
        continue
    for device in devices:
        if device.get('isAvailable') and device['name'].startswith('iPhone'):
            print(device['udid'])
            raise SystemExit(0)
raise SystemExit('No available iPhone simulator in this runner image')
PY
)"
xcrun simctl bootstatus "$SIMULATOR_ID" -b

xcodebuild test \
  -project BenbenDoor.xcodeproj -scheme BenbenDoor \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -parallel-testing-enabled NO \
  -derivedDataPath build/ci/DerivedData \
  -resultBundlePath build/ci/ProtocolTests.xcresult \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  | tee build/ci/tests.log

# Device SDK, not simulator SDK: package arm64 device binaries for later signing.
xcodebuild archive \
  -project BenbenDoor.xcodeproj -scheme BenbenDoor \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/ci/BenbenDoor.xcarchive \
  -derivedDataPath build/ci/DerivedData-device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  | tee build/ci/archive.log

python3 ci/package-unsigned.py
shasum -a 256 dist/BenbenDoor-unsigned.ipa | tee build/ci/ipa-sha256.txt
