#!/bin/zsh
# Runs the Swift tests and the firewall helper's tests. Works with only the Command Line Tools,
# which ship Swift Testing outside the default search path.
set -euo pipefail
cd "${0:A:h}/.."
DEV="$(xcode-select -p)"
F="$DEV/Library/Developer/Frameworks"
L="$DEV/Library/Developer/usr/lib"
swift test --build-system native \
  -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" \
  -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
sh Tests/helper-test.sh
