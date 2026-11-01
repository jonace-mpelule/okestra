#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VIDEO_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/okestra-video-checks.XXXXXX")
trap 'rm -rf "$VIDEO_TEST_DIR"' EXIT HUP INT TERM
swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework AVKit -framework Network \
  "$ROOT"/apps/okestra-device/Core/*.swift \
  "$ROOT/apps/okestra-device/Transport.swift" "$ROOT/apps/okestra-device/DeveloperTransport.swift" \
  "$ROOT/apps/okestra-device/DeviceConvenience.swift" "$ROOT/apps/okestra-device/WorkspaceCanvas.swift" \
  "$ROOT/apps/okestra-device/ScreenshotEditorModel.swift" "$ROOT/apps/okestra-device/ScreenshotEditor.swift" \
  "$ROOT/apps/okestra-device/VideoReviewModel.swift" "$ROOT/apps/okestra-device/VideoReviewWorkspace.swift" \
  "$ROOT/apps/okestra-device/EditorTests/VideoReviewChecks.swift" -o "$VIDEO_TEST_DIR/VideoChecks"
"$VIDEO_TEST_DIR/VideoChecks"
