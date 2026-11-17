"""Check actual build argument setup with the runner's /bin/bash, including 3.2."""
from pathlib import Path
import subprocess

script = Path(__file__).with_name('build-ios.sh')
source = script.read_text(encoding='utf-8')
start = source.index("CONTROL_SWIFT_FLAGS=")
end = source.index("printf '%s\\n'", start)
setup = source[start:end]
assert source.count('"$CONTROL_SWIFT_FLAGS"') == 2
assert '${CONTROL_SWIFT_FLAGS[@]}' not in source
subprocess.run(['/bin/bash', '-n', str(script)], check=True)
for major in [26, 27, 28]:
    # Execute the real setup under nounset. A single, literal argument must
    # reach xcodebuild, with $(inherited) unexpanded and the gate only on 27+.
    probe = 'set -euo pipefail\nSDK_MAJOR="$1"\n' + setup + '''
set -- "$CONTROL_SWIFT_FLAGS"
test "$#" -eq 1
printf 'ARG=%s\\n' "$1"
'''
    output = subprocess.check_output(['/bin/bash', '-c', probe, 'test-build-flags', str(major)], text=True)
    actual = next(line[4:] for line in output.splitlines() if line.startswith('ARG='))
    expected = 'OTHER_SWIFT_FLAGS=$(inherited)' + (' -D BENBEN_IOS27_SDK' if major >= 27 else '')
    assert actual == expected, (major, actual, expected)
    print(f'SDK {major}: nounset-safe, one xcodebuild argument, inherited flags preserved')
