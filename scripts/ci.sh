#!/bin/bash
# v437: the same steps on a developer's Mac and on the CI server.
#   scripts/ci.sh build   generate the Xcode project and build the app
#   scripts/ci.sh test    generate the project and run the unit tests
set -euo pipefail
cd "$(dirname "$0")/.."

# v504: the regression guard runs first (see scripts/guard.sh)
scripts/guard.sh

command -v xcodegen >/dev/null || { echo "xcodegen is missing: brew install xcodegen" >&2; exit 1; }
xcodegen generate

case "${1:-build}" in
  build)
    xcodebuild -project Indra.xcodeproj -scheme Indra -configuration Debug \
      -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build ;;
  test)
    xcodebuild -project Indra.xcodeproj -scheme Indra -configuration Debug \
      -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test ;;
  *)
    echo "usage: scripts/ci.sh [build|test]" >&2; exit 2 ;;
esac
