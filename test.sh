#!/bin/zsh
# Offline only: no optical device operations are part of this test entry point.
set -euo pipefail
project_dir=${0:A:h}
test_dir=$(mktemp -d /tmp/discmate-tests.XXXXXX)
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -Wall -Wextra -Werror -isysroot "$sdk_path" -target arm64-apple-macos13 \
  -c "$project_dir/Sources/DeviceBridge.c" -o "$test_dir/bridge.o"
CLANG_MODULE_CACHE_PATH=/tmp/discmate-clang-cache SDKROOT="$sdk_path" \
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos13 \
  -import-objc-header "$project_dir/Sources/DeviceBridge.h" \
  "$project_dir/Sources/ISO9660.swift" "$project_dir/Sources/DVDSessionReader.swift" \
  "$project_dir/Sources/TestAppendService.swift" "$project_dir/Tests/CoreTests.swift" \
  "$project_dir/Tests/AppendProofTests.swift" \
  "$project_dir/Sources/OperationEstimate.swift" "$project_dir/Tests/OperationEstimateTests.swift" \
  "$project_dir/Sources/BurnCompletion.swift" "$project_dir/Tests/BurnCompletionTests.swift" \
  "$project_dir/Sources/BurnTaskArchive.swift" \
  "$project_dir/Sources/IncrementalISO.swift" "$project_dir/Tests/IncrementalISOTests.swift" \
  "$project_dir/Sources/ISOTrackLayout.swift" \
  "$test_dir/bridge.o" -framework IOKit -framework DiskArbitration -framework DiscRecording -o "$test_dir/core-tests"
"$test_dir/core-tests" "$@"
