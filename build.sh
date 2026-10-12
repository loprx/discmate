#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
app_dir="$project_dir/build/DiscMate.app"
discmate_version=${DISCMATE_VERSION:-0.3.0}
discmate_build=${DISCMATE_BUILD_NUMBER:-1}
[[ "$discmate_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'DISCMATE_VERSION must be major.minor.patch'; exit 1; }
[[ "$discmate_build" =~ '^[1-9][0-9]*$' ]] || { print -u2 'DISCMATE_BUILD_NUMBER must be positive'; exit 1; }
discmate_signing_identity=${DISCMATE_SIGNING_IDENTITY:--}
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Helpers"
zsh "$project_dir/build-icon.sh"
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -Wall -Wextra -Werror -O2 -isysroot "$sdk_path" -target arm64-apple-macos13 \
  -c "$project_dir/Sources/DeviceBridge.c" -o "$project_dir/build/DeviceBridge.o"
xcrun clang -Wall -Wextra -Werror -O2 -isysroot "$sdk_path" -target arm64-apple-macos13 \
  -c "$project_dir/Sources/MountAuthorization.c" -o "$project_dir/build/MountAuthorization.o"
xcrun clang -Wall -Wextra -Werror -O2 -isysroot "$sdk_path" -target arm64-apple-macos13 \
  "$project_dir/Helpers/DiscMateMount.c" "$project_dir/build/DeviceBridge.o" \
  -framework IOKit -framework CoreFoundation -o "$app_dir/Contents/Helpers/DiscMateMount"
if [[ "$discmate_signing_identity" == '-' ]]; then
  codesign --force --sign - "$app_dir/Contents/Helpers/DiscMateMount" >/dev/null
else
  codesign --force --options runtime --timestamp --sign "$discmate_signing_identity" "$app_dir/Contents/Helpers/DiscMateMount" >/dev/null
fi
CLANG_MODULE_CACHE_PATH=/tmp/discmate-clang-cache \
SWIFT_MODULECACHE_PATH=/tmp/discmate-swift-cache \
SDKROOT="$sdk_path" \
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos13 \
  -import-objc-header "$project_dir/Sources/DeviceBridge.h" \
  "$project_dir/DiscMate.swift" "$project_dir"/Sources/*.swift "$project_dir/build/DeviceBridge.o" "$project_dir/build/MountAuthorization.o" \
  -o "$app_dir/Contents/MacOS/DiscMate" \
  -framework AppKit -framework SwiftUI -framework DiscRecording -framework DiscRecordingUI -framework DiskArbitration -framework IOKit -framework Security
cat > "$app_dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>DiscMate</string>
  <key>CFBundleIdentifier</key><string>local.discmate.app</string>
  <key>CFBundleName</key><string>DiscMate</string>
  <key>CFBundleIconFile</key><string>DiscMate.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$discmate_version</string>
  <key>CFBundleVersion</key><string>$discmate_build</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
EOF
if [[ "$discmate_signing_identity" == '-' ]]; then
  codesign --force --sign - "$app_dir" >/dev/null
else
  codesign --force --options runtime --timestamp --sign "$discmate_signing_identity" "$app_dir" >/dev/null
fi
echo "$app_dir"
