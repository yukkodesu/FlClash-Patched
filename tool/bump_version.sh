#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pubspec_file="${PUBSPEC_FILE:-"$script_dir/../pubspec.yaml"}"
[[ "${1:-revision}" == revision && $# -le 1 ]] || {
  echo 'Usage: tool/bump_version.sh [revision] (keep the upstream base; increment +N)' >&2
  exit 64
}
version="$(sed -n 's/^version: //p' "$pubspec_file" | tr -d '\r')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[1-9][0-9]*$ ]] || {
  echo 'Version must be X.Y.Z+N with a positive fork revision' >&2
  exit 1
}
revision="${version##*+}"
[[ ! "$revision" =~ ^20[0-9]{8}$ ]] || {
  echo 'Replace the legacy date build number with a fork revision first' >&2
  exit 1
}
new_version="${version%%+*}+$((revision + 1))"
sed -i.bak "s/^version: .*/version: $new_version/" "$pubspec_file"
rm -f "$pubspec_file.bak"
echo "$version -> $new_version"
