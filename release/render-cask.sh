#!/bin/zsh
# Render a cask using the SHA-256 of the exact ZIP destined for GitHub Releases.
set -euo pipefail
project_dir=${0:A:h:h}
owner=${1:?Usage: render-cask.sh GITHUB_OWNER RELEASE_ZIP [OUTPUT]}
archive=${2:?Usage: render-cask.sh GITHUB_OWNER RELEASE_ZIP [OUTPUT]}
output=${3:-"$project_dir/dist/tap/Casks/discmate.rb"}
[[ "$owner" =~ '^[A-Za-z0-9][A-Za-z0-9-]*$' ]] || { print -u2 'Invalid GitHub owner'; exit 1; }
[[ -f "$archive" ]] || { print -u2 "Archive not found: $archive"; exit 1; }
version=$(/usr/bin/basename "$archive")
version=${version#DiscMate-v}
# Accept the release name and the local candidate name, which carries the build
# number after the version: DiscMate-v0.3.10-2026102407-macos-arm64.zip.
if [[ "$version" =~ '^([0-9]+\.[0-9]+\.[0-9]+)(-[0-9]+)?-macos-arm64\.zip$' ]]; then
  version=$match[1]
  if [[ -n "$match[2]" ]]; then
    print -u2 "warning: '$archive' looks like a local candidate build; the cask url names DiscMate-v$version-macos-arm64.zip, so publish that exact file if this checksum is to stay valid"
  fi
else
  print -u2 'Expected DiscMate-vVERSION[-BUILD]-macos-arm64.zip'
  exit 1
fi
checksum=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')
/usr/bin/python3 - "$project_dir/release/tap/Casks/discmate.rb.template" "$output" "$owner" "$version" "$checksum" <<'PY'
from pathlib import Path
import sys

template, output, owner, version, checksum = sys.argv[1:]
text = Path(template).read_text()
for key, value in (("__OWNER__", owner), ("__VERSION__", version), ("__SHA256__", checksum)):
    text = text.replace(key, value)
target = Path(output)
target.parent.mkdir(parents=True, exist_ok=True)
if target.exists():
    raise SystemExit(f"Cask already exists: {target}")
target.write_text(text)
print(f"Cask: {target}")
print(f"SHA-256: {checksum}")
PY
