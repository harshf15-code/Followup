#!/bin/zsh
# Runs the tests. With only the Command Line Tools (no Xcode), Swift Testing
# lives outside the default search path, so point the compiler at it.
set -e
cd "$(dirname "$0")"
CLT=/Library/Developer/CommandLineTools/Library/Developer
swift test \
  -Xswiftc -F$CLT/Frameworks \
  -Xlinker -F$CLT/Frameworks \
  -Xlinker -rpath -Xlinker $CLT/Frameworks \
  -Xlinker -rpath -Xlinker $CLT/usr/lib "$@"
