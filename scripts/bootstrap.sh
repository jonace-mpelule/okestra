#!/bin/sh
set -eu

repo=jonace-mpelule/okestra
role=${1:-}

fail() {
  printf 'Okestra installer: %s\n' "$*" >&2
  exit 1
}

case "$role" in
  server|client) ;;
  *) fail 'usage: sh bootstrap.sh server|client' ;;
esac

command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v tar >/dev/null 2>&1 || fail 'tar is required'
[ -r /dev/tty ] || fail 'run this command in an interactive terminal'

os=$(uname -s)
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) fail 'only Intel/AMD64 and ARM64 computers are supported' ;;
esac

case "$role:$os" in
  server:Linux) package=okestra-service; platform=linux ;;
  client:Linux) package=okestra; platform=linux ;;
  client:Darwin) package=okestra; platform=darwin ;;
  server:*) fail 'the server requires Linux with Docker Engine and systemd' ;;
  *) fail 'the CLI requires macOS or Linux' ;;
esac

if [ "$role" = server ]; then
  command -v sudo >/dev/null 2>&1 || fail 'sudo is required for server installation'
  command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is required'
else
  if [ "$os" = Darwin ]; then
    command -v shasum >/dev/null 2>&1 || fail 'shasum is required'
  else
    command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is required'
  fi
fi

release_page="https://github.com/$repo/releases/latest"
release_url=$(curl -fsSL --retry 3 --proto '=https' --proto-redir '=https' \
  -o /dev/null -w '%{url_effective}' "$release_page") || fail 'could not find the latest public release'
case "$release_url" in
  "https://github.com/$repo/releases/tag/v"*) tag=${release_url##*/} ;;
  *) fail "unexpected latest-release URL: $release_url" ;;
esac
version=${tag#v}
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "invalid release version: $tag"

archive="${package}_${version}_${platform}_${arch}.tar.gz"
base="https://github.com/$repo/releases/download/$tag"
workdir=$(mktemp -d "${TMPDIR:-/tmp}/okestra-install.XXXXXX") || fail 'could not make a temporary directory'
trap 'rm -rf "$workdir"' EXIT HUP INT TERM

printf 'Downloading Okestra %s for %s/%s...\n' "$tag" "$platform" "$arch"
curl -fsSL --retry 3 --proto '=https' --proto-redir '=https' \
  -o "$workdir/$archive" "$base/$archive" || fail "release asset not found: $archive"
curl -fsSL --retry 3 --proto '=https' --proto-redir '=https' \
  -o "$workdir/SHA256SUMS" "$base/SHA256SUMS" || fail 'release checksums not found'

expected=$(awk -v name="$archive" '$2 == name { print $1 }' "$workdir/SHA256SUMS")
[ -n "$expected" ] || fail "checksum missing for $archive"
if [ "$os" = Darwin ]; then
  actual=$(shasum -a 256 "$workdir/$archive" | awk '{ print $1 }')
else
  actual=$(sha256sum "$workdir/$archive" | awk '{ print $1 }')
fi
[ "$actual" = "$expected" ] || fail "checksum mismatch for $archive"
printf 'Checksum verified. Opening setup menu...\n'

tar -xzf "$workdir/$archive" -C "$workdir" || fail 'could not unpack the release archive'
if [ "$role" = server ]; then
  sudo "$workdir/install-service.sh" </dev/tty
else
  "$workdir/install-cli.sh" </dev/tty
fi
