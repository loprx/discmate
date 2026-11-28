#!/bin/zsh
# Package the current arm64 build for a GitHub release and a self-hosted tap.
#   zsh release/package.sh [SOURCE_TREE] [ARCHIVE]
# ARCHIVE overrides the output path, which local candidate runs use so that an
# already-published dist/DiscMate-vVERSION-macos-arm64.zip is never overwritten.
set -euo pipefail
project_dir=${1:-${0:A:h:h}}
app_dir="$project_dir/build/DiscMate.app"
[[ -d "$app_dir" ]] || { print -u2 'Build the app first'; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_dir/Contents/Info.plist")
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid bundle version'; exit 1; }
[[ "$build" =~ '^[1-9][0-9]*$' ]] || { print -u2 'Invalid bundle build number'; exit 1; }
/usr/bin/codesign --verify --deep --strict "$app_dir"
[[ $(/usr/bin/codesign -dv --verbose=4 "$app_dir" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p') == 'local.discmate.app' ]] \
  || { print -u2 'Unexpected bundle identifier'; exit 1; }
[[ $(/usr/bin/lipo -archs "$app_dir/Contents/MacOS/DiscMate") == 'arm64' ]] || { print -u2 'Expected arm64 executable'; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app_dir/Contents/Info.plist") == 'DiscMate.icns' ]]
[[ -s "$app_dir/Contents/Resources/DiscMate.icns" ]]
mkdir -p "$project_dir/dist"
archive=${2:-"$project_dir/dist/DiscMate-v${version}-macos-arm64.zip"}
[[ ! -e "$archive" ]] || { print -u2 "Archive already exists: $archive"; exit 1; }
/bin/mkdir -p "${archive:h}"
stage=$(/usr/bin/mktemp -d "${archive:h}/.discmate-package.XXXXXX")
trap '/bin/rm -rf "$stage"' EXIT
staged_zip="$stage/${archive:t}"
# --sequesterRsrc keeps resource forks and extended attributes out of the ZIP's
# file namespace, so extracting cannot scatter AppleDouble files next to the
# bundle. The signature still verifies after extraction because it lives in
# Contents/_CodeSignature, not in an extended attribute.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$staged_zip"
/usr/bin/ditto -x -k "$staged_zip" "$stage/extracted"
extracted_app="$stage/extracted/DiscMate.app"
/usr/bin/codesign --verify --deep --strict "$extracted_app"
for file in Info.plist MacOS/DiscMate Helpers/DiscMateMount; do
  /usr/bin/cmp "$app_dir/Contents/$file" "$extracted_app/Contents/$file"
done
/bin/mv -n "$staged_zip" "$archive"
[[ ! -e "$staged_zip" ]] || { print -u2 "Archive already exists: $archive"; exit 1; }
print "Verified package $version ($build), arm64"
/usr/bin/shasum -a 256 "$archive"
