#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."

mode=""
want_version=""
do_push=0
assume_yes=0
dry_run=0
remote=my

usage() {
  cat <<'EOF'
Usage: tool/release.sh <pre|stable> [--version X.Y.Z+N] [--push] [--yes] [--dry-run]

Keep the upstream base version and publish a positive fork revision, vX.Y.Z+N.
pre/stable selects the release channel independently of the tag.
The default retains an unpublished pubspec revision or advances past fork tags.
--push publishes the branch and tag only to the verified user fork (my).
--dry-run reports the plan without changing files, commits or tags.
EOF
}

die() { echo "error: $*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    pre | stable) [[ -z "$mode" ]] || die 'mode given twice'; mode="$1" ;;
    --version) (($# >= 2)) || die '--version needs a value'; shift; want_version="$1" ;;
    --version=*) want_version="${1#*=}" ;;
    --push) do_push=1 ;;
    --yes | -y) assume_yes=1 ;;
    --dry-run) dry_run=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done
[[ -n "$mode" ]] || { usage >&2; exit 64; }
[[ -z "$(git status --porcelain)" ]] || die 'working tree has uncommitted changes'
branch="$(git symbolic-ref --quiet --short HEAD)" || die 'detached HEAD; check out a branch first'

if ((do_push)); then
  push_urls="$(git remote get-url --push --all "$remote")" || die "missing fork remote: $remote"
  while IFS= read -r push_url; do
    case "$push_url" in
      git@github.com:yukkodesu/FlClash-Patched.git | https://github.com/yukkodesu/FlClash-Patched.git | https://github.com/yukkodesu/FlClash-Patched | ssh://git@github.com/yukkodesu/FlClash-Patched.git) ;;
      *) die "remote $remote must push only to yukkodesu/FlClash-Patched" ;;
    esac
  done <<<"$push_urls"
fi

current="$(sed -n 's/^version: //p' pubspec.yaml | tr -d '\r')"
[[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[1-9][0-9]*$ ]] || die 'pubspec version must be X.Y.Z+N with a positive fork revision'
base="${current%%+*}"
revision="${current##*+}"
[[ ! "$revision" =~ ^20[0-9]{8}$ ]] || die 'replace the legacy date build number with a fork revision before releasing'
[[ "$(sed -n 's/^release_channel: //p' build_config.yaml | tr -d '\r')" =~ ^(pre|stable)$ ]] || die 'build_config.yaml needs release_channel: pre or stable'
fork_tags="$(git ls-remote --tags "$remote" "refs/tags/v$base+*")" || die "cannot read tags from fork remote $remote"
last=0
while read -r object ref; do
  candidate="${ref#refs/tags/v}"
  number="${candidate##*+}"
  if [[ "${candidate%%+*}" == "$base" && "$number" =~ ^[1-9][0-9]*$ ]] && ((number > last)); then
    last="$number"
  fi
done <<<"$fork_tags"

if [[ -n "$want_version" ]]; then
  [[ "$want_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[1-9][0-9]*$ ]] || die '--version must be X.Y.Z+N'
  [[ "${want_version%%+*}" == "$base" ]] || die '--version must retain the pubspec upstream base'
  revision="${want_version##*+}"
  ((revision > last)) || die "$want_version has already been published or superseded"
else
  ((revision > last)) || revision=$((last + 1))
  while git show-ref --verify --quiet "refs/tags/v$base+$revision"; do
    revision=$((revision + 1))
  done
fi
version="$base+$revision"
tag="v$version"
git show-ref --verify --quiet "refs/tags/$tag" && die "$tag already exists"

echo "channel   : $mode"
echo "branch    : $branch"
echo "version   : $current -> $version"
echo "tag       : $tag"
echo "remote    : $remote"
echo "prerelease: $([[ "$mode" == pre ]] && echo true || echo false)"
if ((dry_run)); then
  echo 'dry run: nothing was changed'
  exit 0
fi
if ((assume_yes == 0)); then
  read -r -p "Proceed with $tag ($mode)? [y/N] " reply </dev/tty || die 'pass --yes to run unattended'
  [[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]] || { echo 'Cancelled. Nothing was changed.'; exit 0; }
fi

committed=0
restore() {
  ((committed)) || git restore --source=HEAD --staged --worktree -- pubspec.yaml build_config.yaml
}
trap restore EXIT
sed -i.bak "s/^version: .*/version: $version/" pubspec.yaml
sed -i.bak "s/^release_channel: .*/release_channel: $mode/" build_config.yaml
rm -f pubspec.yaml.bak build_config.yaml.bak
if ! git diff --quiet -- pubspec.yaml build_config.yaml; then
  git add pubspec.yaml build_config.yaml
  git commit -m "chore(release): $tag"
fi
committed=1
git tag "$tag"
echo "tagged $tag at $(git rev-parse --short HEAD)"
if ((do_push)); then
  git push --atomic "$remote" "$branch" "$tag"
else
  echo "Nothing was pushed. To publish: git push --atomic $remote $branch $tag"
fi
