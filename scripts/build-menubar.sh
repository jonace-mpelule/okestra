#!/bin/sh
set -eu

if [ "$(uname -s)" != Darwin ]; then
  printf '%s\n' 'Okestra Menu requires macOS.' >&2
  exit 1
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/dist/Okestra Menu.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/okestra-menu.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM
for arch in arm64 x86_64; do
  swiftc -parse-as-library -O -target "$arch-apple-macosx13.0" \
    -framework SwiftUI -framework AppKit \
    "$ROOT/apps/okestra-menubar/OkestraMenu.swift" \
    -o "$BUILD_DIR/OkestraMenu-$arch"
done
lipo -create "$BUILD_DIR/OkestraMenu-arm64" "$BUILD_DIR/OkestraMenu-x86_64" \
  -output "$APP/Contents/MacOS/OkestraMenu"
cp "$ROOT/apps/okestra-menubar/Info.plist" "$APP/Contents/Info.plist"
if [ -n "${OKESTRA_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $OKESTRA_VERSION" "$APP/Contents/Info.plist"
fi
printf 'Built %s\n' "$APP"
