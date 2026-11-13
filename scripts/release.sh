#!/bin/bash
# v547: publishes a build that ANY Mac can install from inside the app (Settings > About > Updates): no git, no Xcode, no token.
#   scripts/release.sh            build, zip, checksum, write latest.json (in build/dist)
#   scripts/release.sh --publish  also upload them as a GitHub release (needs the `gh` command, signed in once with `gh auth login`)
# The source repository stays private. Only the zip and latest.json go to a PUBLIC repository (default shadow011-dev/Indra-releases;
# create it once, empty, public). The app reads  https://github.com/<repo>/releases/latest/download/latest.json
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${INDRA_RELEASE_REPO:-shadow011-dev/Indra-releases}"
V=$(tr -d '[:space:]' < VERSION)
scripts/guard.sh
command -v xcodegen >/dev/null && xcodegen generate --quiet
rm -rf build/release build/dist
xcodebuild -project Indra.xcodeproj -scheme Indra -configuration Release -derivedDataPath build/release \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES build | tail -3
APP="build/release/Build/Products/Release/Indra.app"
test -d "$APP"
BUILT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
[ "$BUILT" = "$V" ] || { echo "the built app says build $BUILT but VERSION says $V" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
mkdir -p build/dist
ZIP="build/dist/Indra-$V.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
printf '{\n  "build": %s,\n  "url": "https://github.com/%s/releases/download/v%s/Indra-%s.zip",\n  "sha256": "%s"\n}\n' \
  "$V" "$REPO" "$V" "$V" "$SHA" > build/dist/latest.json
echo "built build/dist/Indra-$V.zip  sha256 $SHA"
if [ "${1:-}" = "--publish" ]; then
  command -v gh >/dev/null || { echo "gh is missing: brew install gh && gh auth login" >&2; exit 1; }
  gh release create "v$V" "$ZIP" build/dist/latest.json --repo "$REPO" --title "Indra $V" --notes "Indra build $V"
  echo "published: the apps will find build $V within 12 hours, or at once with Check for updates"
else
  echo "not published. Upload both files in build/dist to a release named v$V of $REPO, or run: scripts/release.sh --publish"
fi
