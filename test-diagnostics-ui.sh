#!/bin/zsh
# Build only. Synthetic reports; no DiscRecording or device sources are linked.
set -euo pipefail
project_dir=${0:A:h}
fixture_dir=$(mktemp -d /tmp/discmate-diagnostics-ui.XXXXXX)
app_dir="$fixture_dir/DiagnosticsPreview.app"
mkdir -p "$app_dir/Contents/MacOS"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos13 \
  -module-cache-path /tmp/discmate-swift-cache \
  "$project_dir/Sources/DiagnosticReport.swift" "$project_dir/Sources/DiagnosticPreview.swift" \
  "$project_dir/Sources/DiagnosticsView.swift" "$project_dir/Tests/DiagnosticPreviewFixture.swift" \
  "$project_dir/Tests/DiagnosticsPreviewApp.swift" -framework SwiftUI -framework AppKit \
  -o "$app_dir/Contents/MacOS/DiagnosticsPreview"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DiagnosticsPreview</string>
<key>CFBundleIdentifier</key><string>local.discmate.diagnostics.fixture</string>
<key>CFBundleName</key><string>DiagnosticsPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir" >/dev/null
print "$app_dir"
