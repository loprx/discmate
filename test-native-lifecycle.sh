#!/bin/zsh
# Offline: injected backend only. Never enumerates, reads or writes a drive.
set -euo pipefail
project_dir=${0:A:h}
test_dir=$(mktemp -d /tmp/discmate-native-tests.XXXXXX)
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
for source in DeviceBridge MountAuthorization; do
  xcrun clang -Wall -Wextra -Werror -isysroot "$sdk_path" -target arm64-apple-macos13 \
    -c "$project_dir/Sources/$source.c" -o "$test_dir/$source.o"
done
xcrun clang -fobjc-arc -Wall -Wextra -Werror -isysroot "$sdk_path" -target arm64-apple-macos13 \
  -c "$project_dir/Sources/SystemBurnPanels.m" -o "$test_dir/SystemBurnPanels.o"
CLANG_MODULE_CACHE_PATH=/tmp/discmate-clang-cache SDKROOT="$sdk_path" \
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos13 \
  -import-objc-header "$project_dir/Sources/DeviceBridge.h" \
  "$project_dir"/Sources/*.swift "$project_dir/Tests/FirstDataLifecycleTests.swift" \
  "$test_dir"/*.o -framework AppKit -framework SwiftUI -framework DiscRecording -framework DiscRecordingUI \
  -framework DiskArbitration -framework IOKit -framework Security -o "$test_dir/native-tests"
"$test_dir/native-tests"
