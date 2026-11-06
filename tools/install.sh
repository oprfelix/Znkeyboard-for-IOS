#!/usr/bin/env bash
# Builds and installs on the connected iPhone without a developer disk image, which an Xcode older
# than the phone's system cannot mount. Needs ideviceinstaller (brew) and Xcode signed in.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate >/dev/null
xcodebuild -project ZnKeyboard.xcodeproj -target ZnKeyboard -sdk iphoneos -configuration Debug -arch arm64 \
  -allowProvisioningUpdates SYMROOT="$PWD/.build/device" build | grep -E ' error:|^error|BUILD (SUCCEEDED|FAILED)' | sort -u
rm -rf .build/ipa
mkdir -p .build/ipa/Payload
cp -R .build/device/Debug-iphoneos/ZnKeyboard.app .build/ipa/Payload/
(cd .build/ipa && zip -qry ZnKeyboard.ipa Payload)
ideviceinstaller install .build/ipa/ZnKeyboard.ipa | tail -1
