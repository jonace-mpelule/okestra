#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EDITOR_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/okestra-editor-checks.XXXXXX")
trap 'rm -rf "$EDITOR_TEST_DIR"' EXIT HUP INT TERM
swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework Network \
  "$ROOT"/apps/okestra-device/Core/*.swift \
  "$ROOT/apps/okestra-device/Transport.swift" \
  "$ROOT/apps/okestra-device/DeveloperTransport.swift" \
  "$ROOT/apps/okestra-device/DeviceConvenience.swift" \
  "$ROOT/apps/okestra-device/WorkspaceCanvas.swift" \
  "$ROOT/apps/okestra-device/ScreenshotEditorModel.swift" \
  "$ROOT/apps/okestra-device/ScreenshotEditor.swift" \
  "$ROOT/apps/okestra-device/EditorTests/ScreenshotEditorChecks.swift" \
  -o "$EDITOR_TEST_DIR/EditorChecks"
"$EDITOR_TEST_DIR/EditorChecks"
