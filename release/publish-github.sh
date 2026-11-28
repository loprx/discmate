#!/bin/zsh
# Publish the verified CI artifact, then download the public copy for Homebrew.
set -euo pipefail
repository=${1:?GitHub repository required}
tag=${2:?Release tag required}
commit=${3:?Tagged commit required}
archive=${4:?Build archive required}
checksum=${5:?Build checksum required}
output_dir=${6:?Download directory required}
asset_name="DiscMate-${tag}-macos-arm64.zip"

[[ "$tag" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' && "${archive:t}" == "$asset_name" ]] \
  || { print -u2 "Invalid release tag or archive name: $tag / ${archive:t}"; exit 1; }
[[ $(shasum -a 256 "$archive" | awk '{print $1}') == "$checksum" ]] \
  || { print -u2 "CI artifact checksum mismatch: $asset_name"; exit 1; }
[[ $(gh api "repos/$repository/commits/refs%2Ftags%2F$tag" --jq .sha) == "$commit" ]] \
  || { print -u2 "Release tag $tag no longer points to $commit"; exit 1; }

releases=$(gh api "repos/$repository/releases?per_page=100" --paginate --slurp)
release=$(jq -c --arg tag "$tag" '.[][] | select(.tag_name == $tag)' <<< "$releases")
if [[ -z "$release" ]]; then
  print "Creating draft for $tag at $commit"
  gh release create "$tag" --repo "$repository" --verify-tag --draft --generate-notes
  release=$(gh release view "$tag" --repo "$repository" --json isDraft,isPrerelease,assets \
    --jq '{draft: .isDraft, prerelease: .isPrerelease, assets}')
fi
[[ $(jq -r .prerelease <<< "$release") == false ]] \
  || { print -u2 "Expected a stable release for $tag"; exit 1; }
draft=$(jq -r .draft <<< "$release")
asset=$(jq -c --arg name "$asset_name" '.assets[] | select(.name == $name)' <<< "$release")
if [[ "$draft" == true && -z "$asset" ]]; then
  print "Uploading $asset_name ($checksum)"
  gh release upload "$tag" "$archive" --repo "$repository"
  asset=$(gh release view "$tag" --repo "$repository" --json assets \
    --jq ".assets[] | select(.name == \"$asset_name\")")
fi
if [[ $(jq -r .digest <<< "$asset") != "sha256:$checksum" ]]; then
  print -u2 "The asset on GitHub does not match this run's artifact: $asset_name (expected $checksum)"
  exit 1
fi

if [[ "$draft" == true ]]; then
  latest_version=$(
    { jq -r '.[][] | select(.draft == false and .prerelease == false) | .tag_name |
        select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) | ltrimstr("v")' <<< "$releases"
      print "${tag#v}"
    } | LC_ALL=C sort -V | tail -n 1
  )
  latest=false
  [[ "$tag" != "v$latest_version" ]] || latest=true
  print "Publishing $tag (latest=$latest)"
  gh release edit "$tag" --repo "$repository" --draft=false --latest="$latest"
fi

mkdir -p "$output_dir"
url="https://github.com/$repository/releases/download/$tag/$asset_name"
curl --fail --location --silent --show-error --retry 3 --output "$output_dir/$asset_name" "$url"
if ! cmp -s "$archive" "$output_dir/$asset_name"; then
  print -u2 "Public download differs from the verified CI artifact: $asset_name"
  exit 1
fi
print "Verified public ZIP: $url (SHA-256 $checksum)"
