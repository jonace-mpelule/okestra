#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: make release [RELEASE_ARGS="--minor"]
       ./scripts/release.sh [--patch|--minor|--major] [--commit-all] [--dry-run]
       ./scripts/release.sh --resume vX.Y.Z

The default is the next patch version (or v0.1.0 for the first release).
If the checkout has changes, the command lists them and asks before committing
everything in this repository. --commit-all opts in without a prompt.
--resume retries a tag/release left incomplete by a previous attempt.
EOF
}

die() { printf 'release: %s\n' "$*" >&2; exit 1; }

bump=patch
commit_all=false
dry_run=false
resume=
while (($#)); do
  case "$1" in
    --patch|--minor|--major) bump=${1#--} ;;
    --commit-all) commit_all=true ;;
    --dry-run) dry_run=true ;;
    --resume) shift; (($#)) || die '--resume needs a tag'; resume=$1 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

for command in git gh make go; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die 'not in a Git repository'
branch=$(git symbolic-ref --quiet --short HEAD) || die 'check out a branch first'

latest_version() {
  git tag -l | sed -nE 's/^v([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' |
    sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

next_version() {
  local latest major minor patch
  latest=$(latest_version)
  if [[ -z "$latest" ]]; then
    printf '0.1.0\n'
    return
  fi
  IFS=. read -r major minor patch <<< "$latest"
  case "$bump" in
    patch) patch=$((patch + 1)) ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    major) major=$((major + 1)); minor=0; patch=0 ;;
  esac
  printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

if [[ -n "$resume" ]]; then
  [[ "$resume" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'resume tag must look like v1.2.3'
  tag=$resume
else
  tag="v$(next_version)"
fi
version=${tag#v}

if "$dry_run"; then
  printf 'Planned release: %s from branch %s\n' "$tag" "$branch"
  printf 'Working tree:\n'
  git status --short --untracked-files=all
  printf 'A live run checks GitHub access, tests, builds, pushes the branch/tag, then publishes six archives and SHA256SUMS.\n'
  exit 0
fi

origin=$(git remote get-url origin 2>/dev/null) || die 'configure a GitHub origin remote first (see README)'
case "$origin" in
  git@github.com:*|https://github.com/*|ssh://git@github.com/*) ;;
  *) die "origin must point to github.com; found: $origin" ;;
esac
gh auth status -h github.com >/dev/null 2>&1 || die 'authenticate first: gh auth login -h github.com'
gh repo view --json nameWithOwner --jq .nameWithOwner >/dev/null || die 'cannot access the GitHub repository for origin'
git fetch origin --tags

if [[ -z "$resume" ]]; then
  previous=$(latest_version)
  if [[ -n "$previous" ]]; then
    previous_commit=$(git rev-parse "refs/tags/v$previous^{commit}") || die "cannot resolve v$previous"
    git merge-base --is-ancestor "$previous_commit" HEAD || die "latest release v$previous is not in this branch; integrate it first"
  fi
  tag="v$(next_version)"
  version=${tag#v}
  git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "$tag already exists"
fi

changes=$(git status --short --untracked-files=all)
if [[ -n "$resume" ]]; then
  [[ -z "$changes" ]] || die 'commit or set aside changes before resuming'
  tag_commit=$(git rev-parse "refs/tags/$tag^{commit}" 2>/dev/null) || die "local tag $tag not found"
  [[ "$(git rev-parse HEAD)" == "$tag_commit" ]] || die "HEAD does not match $tag"
else
  if [[ -n "$changes" ]]; then
    printf 'Changes to include in %s:\n%s\n' "$tag" "$changes"
    if ! "$commit_all"; then
      [[ -t 0 ]] || die 'non-interactive run requires --commit-all for a dirty checkout'
      read -r -p 'Commit ALL listed files for this release? [y/N] ' answer
      [[ "$answer" == y || "$answer" == Y ]] || die 'cancelled without changing files'
    fi
  fi
fi

printf 'Checking code...\n'
go vet ./...
go test -race ./...
[[ "$(git status --short --untracked-files=all)" == "$changes" ]] || die 'working tree changed during checks; review it and rerun'

if [[ -z "$resume" && -n "$changes" ]]; then
  git add -A
  git commit -m "chore: release $tag"
fi
git rev-parse HEAD >/dev/null 2>&1 || die 'make an initial commit first'
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || die 'working tree changed during checks'

remote_sha=$(git ls-remote --heads origin "refs/heads/$branch" | awk 'NR == 1 { print $1 }')
if [[ -n "$remote_sha" ]]; then
  git merge-base --is-ancestor "$remote_sha" HEAD || die "origin/$branch is not an ancestor of HEAD; integrate remote changes first"
fi

printf 'Building %s...\n' "$tag"
make VERSION="$version" dist
assets=(
  "dist/okestra_${version}_darwin_amd64.tar.gz"
  "dist/okestra_${version}_darwin_arm64.tar.gz"
  "dist/okestra_${version}_linux_amd64.tar.gz"
  "dist/okestra_${version}_linux_arm64.tar.gz"
  "dist/okestra-service_${version}_linux_amd64.tar.gz"
  "dist/okestra-service_${version}_linux_arm64.tar.gz"
  dist/SHA256SUMS
)
for asset in "${assets[@]}"; do [[ -s "$asset" ]] || die "missing asset: $asset"; done
if command -v sha256sum >/dev/null 2>&1; then
  (cd dist && sha256sum -c SHA256SUMS)
else
  (cd dist && shasum -a 256 -c SHA256SUMS)
fi

if [[ -z "$resume" ]]; then
  git tag -a "$tag" -m "Okestra $tag"
fi
printf 'Pushing %s and %s...\n' "$branch" "$tag"
git push --atomic origin "HEAD:refs/heads/$branch" "refs/tags/$tag"

if gh release view "$tag" --json isDraft --jq .isDraft >/dev/null 2>&1; then
  [[ -n "$resume" ]] || die "release $tag already exists; use --resume $tag if it is a draft"
  is_draft=$(gh release view "$tag" --json isDraft --jq .isDraft)
  [[ "$is_draft" == true ]] || die "$tag is already published"
  existing_assets=$(gh release view "$tag" --json assets --jq '.assets[].name')
  missing_assets=()
  for asset in "${assets[@]}"; do
    name=${asset##*/}
    if ! printf '%s\n' "$existing_assets" | grep -Fxq "$name"; then
      missing_assets+=("$asset")
    fi
  done
  if ((${#missing_assets[@]})); then gh release upload "$tag" "${missing_assets[@]}"; fi
else
  gh release create "$tag" "${assets[@]}" --verify-tag --draft --generate-notes --title "Okestra $tag"
fi
gh release edit "$tag" --draft=false
printf 'Published %s: ' "$tag"
gh release view "$tag" --json url --jq .url
