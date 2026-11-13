#!/bin/bash
# Builds the Now Playing helper library ONCE, on the build machine, and puts it inside Indra.app.
# People who install Indra then need no Xcode / command line tools (the old design compiled it on
# every Mac, which failed on Macs without them and made macOS pop up "clang requires developer tools").
set -euo pipefail

SRC="${SRCROOT}/Helper/indra_np.m"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
OUT="${DERIVED_FILE_DIR}/indra_np.dylib"
mkdir -p "${DEST}" "${DERIVED_FILE_DIR}"

# perl runs as arm64e or x86_64 depending on the Mac, so the library carries both slices.
/usr/bin/xcrun clang -dynamiclib -fobjc-arc -fblocks -O1 \
    -mmacosx-version-min=11.0 \
    -arch arm64 -arch x86_64 \
    -framework Foundation \
    -o "${OUT}" "${SRC}"
/usr/bin/codesign --force --sign - "${OUT}"

cp -f "${OUT}" "${DEST}/indra_np.dylib"
cp -f "${SRC}" "${DEST}/indra_np.m"
