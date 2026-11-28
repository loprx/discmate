#!/bin/zsh
# Update only the DiscMate cask, using the current blob SHA as a write guard.
set -euo pipefail
repository=${1:?Homebrew tap repository required}
cask=${2:?Rendered cask required}
: "${GH_TOKEN:?Set the HOMEBREW_TAP_TOKEN secret to a token with write access to the tap}"

version_from_cask() {
  awk -F '"' '/^[[:space:]]*version "[0-9]+\.[0-9]+\.[0-9]+"$/ { print $2 }'
}

ruby -c "$cask"
version=$(version_from_cask < "$cask")
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid version in rendered cask'; exit 1; }

endpoint="repos/$repository/contents/Casks/discmate.rb"
current=$(gh api "$endpoint?ref=main")
current_blob=$(jq -er .sha <<< "$current")
expected_blob=$(git hash-object "$cask")
if [[ "$current_blob" == "$expected_blob" ]]; then
  print "Homebrew already serves DiscMate $version ($current_blob)"
  exit 0
fi

current_version=$(jq -er .content <<< "$current" | /usr/bin/base64 -D | version_from_cask)
[[ "$current_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] \
  || { print -u2 'Invalid version in the live cask'; exit 1; }
if [[ "$current_version" == "$version" ]]; then
  print -u2 "Refusing to replace a different cask at the same version ($version)"
  exit 1
fi
if [[ $(printf '%s\n' "$version" "$current_version" | LC_ALL=C sort -V | tail -n 1) == "$current_version" ]]; then
  print "Homebrew already serves newer DiscMate $current_version; leaving it in place"
  exit 0
fi

content=$(/usr/bin/base64 < "$cask" | tr -d '\n')
tap_commit=$(gh api "$endpoint" --method PUT -f branch=main \
  -f "message=DiscMate $version" -f "sha=$current_blob" -f "content=$content" --jq .commit.sha)
[[ $(gh api "$endpoint?ref=main" --jq .sha) == "$expected_blob" ]] \
  || { print -u2 "Live cask verification failed after tap commit $tap_commit"; exit 1; }
print "Published Homebrew cask $version at https://github.com/$repository/commit/$tap_commit"
