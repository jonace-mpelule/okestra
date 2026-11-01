#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}
JAVA_BIN=${OKESTRA_JAVA:-/opt/homebrew/opt/openjdk@17/bin/java}
JAVAC_BIN=${OKESTRA_JAVAC:-/opt/homebrew/opt/openjdk@17/bin/javac}
JAR_BIN=${OKESTRA_JAR:-/opt/homebrew/opt/openjdk@17/bin/jar}
ANDROID_JAR=${OKESTRA_ANDROID_JAR:-$SDK/platforms/android-31/android.jar}
D8_JAR=${OKESTRA_D8_JAR:-$SDK/build-tools/36.0.0/lib/d8.jar}
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/okestra-network.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM
mkdir -p "$BUILD_DIR/classes" "$BUILD_DIR/dex" "$ROOT/apps/okestra-device/Resources"
"$JAVAC_BIN" --release 8 -g:none -classpath "$ANDROID_JAR" -d "$BUILD_DIR/classes" \
 "$ROOT/apps/okestra-device/Android/NetworkMonitor.java"
"$JAR_BIN" cf "$BUILD_DIR/classes.jar" -C "$BUILD_DIR/classes" .
"$JAVA_BIN" -cp "$D8_JAR" com.android.tools.r8.D8 --min-api 26 --lib "$ANDROID_JAR" \
 --output "$BUILD_DIR/dex" "$BUILD_DIR/classes.jar"
python3 - "$ROOT" "$BUILD_DIR" <<'PY'
import hashlib,pathlib,sys,zipfile
root,build=map(pathlib.Path,sys.argv[1:])
source=root/'apps/okestra-device/Android/NetworkMonitor.java'
output=root/'apps/okestra-device/Resources/okestra-network-monitor-v1.jar'
with zipfile.ZipFile(output,'w',compression=zipfile.ZIP_DEFLATED) as archive:
    for name,data in [('classes.dex',(build/'dex/classes.dex').read_bytes()),
                      ('source.sha256',(hashlib.sha256(source.read_bytes()).hexdigest()+'\n').encode())]:
        item=zipfile.ZipInfo(name,(2026,1,1,0,0,0))
        item.compress_type=zipfile.ZIP_DEFLATED
        archive.writestr(item,data)
print('Built',output)
PY
