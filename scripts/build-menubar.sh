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
mkdir -p "$APP/Contents/Helpers"
for arch in arm64 x86_64; do
 if [ "$arch" = arm64 ]; then goarch=arm64; else goarch=amd64; fi
 GOOS=darwin GOARCH=$goarch go build -trimpath -ldflags "${OKESTRA_LDFLAGS:-}" -o "$BUILD_DIR/okestra-$arch" "$ROOT/cmd/okestra"
done
lipo -create "$BUILD_DIR/okestra-arm64" "$BUILD_DIR/okestra-x86_64" -output "$APP/Contents/Helpers/okestra"
cp "$ROOT/apps/okestra-menubar/Info.plist" "$APP/Contents/Info.plist"
if [ -n "${OKESTRA_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $OKESTRA_VERSION" "$APP/Contents/Info.plist"
fi
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
