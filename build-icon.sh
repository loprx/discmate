#!/bin/zsh
# Only resize/encode the approved artwork; no optical-device access.
set -euo pipefail
project_dir=${0:A:h}
iconset_dir="$project_dir/build/DiscMate.iconset"
resources_dir="$project_dir/build/DiscMate.app/Contents/Resources"
mkdir -p "$iconset_dir" "$resources_dir"
for point_size in 16 32 128 256 512; do
  /usr/bin/sips -z "$point_size" "$point_size" "$project_dir/Assets/DiscMateIcon.png" \
    --out "$iconset_dir/icon_${point_size}x${point_size}.png" >/dev/null
  pixel_size=$((point_size * 2))
  /usr/bin/sips -z "$pixel_size" "$pixel_size" "$project_dir/Assets/DiscMateIcon.png" \
    --out "$iconset_dir/icon_${point_size}x${point_size}@2x.png" >/dev/null
done
CLANG_MODULE_CACHE_PATH=/tmp/discmate-clang-cache \
  xcrun swift "$project_dir/Helpers/PackIcon.swift" "$iconset_dir" "$resources_dir/DiscMate.icns"
