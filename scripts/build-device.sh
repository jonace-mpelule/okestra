#!/bin/sh
set -eu
[ "$(uname -s)" = Darwin ] || { printf '%s\n' 'Okestra Device requires macOS.' >&2; exit 1; }
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/dist/Okestra Device.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
NETWORK_JAR="$ROOT/apps/okestra-device/Resources/okestra-network-monitor-v1.jar"
NETWORK_SOURCE="$ROOT/apps/okestra-device/Android/NetworkMonitor.java"
[ "$(unzip -p "$NETWORK_JAR" source.sha256)" = "$(shasum -a 256 "$NETWORK_SOURCE" | cut -d ' ' -f 1)" ] || {
 printf '%s\n' 'Network monitor is out of date. Run scripts/build-network-monitor.sh.' >&2
 exit 1
}
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/okestra-device.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM
for arch in arm64 x86_64; do
 swiftc -parse-as-library -O -target "$arch-apple-macosx13.0" -framework SwiftUI -framework AppKit -framework AVFoundation -framework Network -framework AVKit \
 "$ROOT"/apps/okestra-device/Core/*.swift \
 "$ROOT/apps/okestra-device/Transport.swift" "$ROOT/apps/okestra-device/DeveloperTransport.swift" \
 "$ROOT/apps/okestra-device/VideoReviewModel.swift" "$ROOT/apps/okestra-device/VideoReviewWorkspace.swift" "$ROOT/apps/okestra-device/WorkspaceCanvas.swift" "$ROOT/apps/okestra-device/ScreenshotEditorModel.swift" "$ROOT/apps/okestra-device/ScreenshotEditor.swift" "$ROOT/apps/okestra-device/DeviceConvenience.swift" "$ROOT/apps/okestra-device/DeviceNetwork.swift" "$ROOT/apps/okestra-device/DeviceNetworkTransport.swift" \
 "$ROOT/apps/okestra-device/DeveloperTools.swift" "$ROOT/apps/okestra-device/DeveloperWorkspace.swift" \
 "$ROOT/apps/okestra-device/DeviceWorkspace.swift" "$ROOT/apps/okestra-device/OkestraDevice.swift" -o "$BUILD_DIR/OkestraDevice-$arch"
 # Bundle a matching CLI so launching the app never invokes an outdated system install.
 if [ "$arch" = arm64 ]; then goarch=arm64; else goarch=amd64; fi
 GOOS=darwin GOARCH=$goarch go build -trimpath -ldflags "${OKESTRA_LDFLAGS:-}" -o "$BUILD_DIR/okestra-$arch" "$ROOT/cmd/okestra"
done
lipo -create "$BUILD_DIR/OkestraDevice-arm64" "$BUILD_DIR/OkestraDevice-x86_64" -output "$APP/Contents/MacOS/OkestraDevice"
lipo -create "$BUILD_DIR/okestra-arm64" "$BUILD_DIR/okestra-x86_64" -output "$APP/Contents/Helpers/okestra"
cp "$ROOT/apps/okestra-device/Info.plist" "$APP/Contents/Info.plist"
if [ -n "${OKESTRA_VERSION:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $OKESTRA_VERSION" "$APP/Contents/Info.plist"; fi
cp "$NETWORK_JAR" "$APP/Contents/Resources/"
cp "$ROOT/third_party/scrcpy/scrcpy-server-3.3.4.jar" "$APP/Contents/Resources/"
cp "$ROOT/third_party/scrcpy/LICENSE" "$APP/Contents/Resources/SCRCPY-LICENSE"
cp "$ROOT/third_party/scrcpy/README.md" "$APP/Contents/Resources/SCRCPY-NOTICE.md"
# Ad-hoc signing gives the locally built bundle a consistent integrity seal; it is not notarization.
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
