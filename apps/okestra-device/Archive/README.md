# Archived project UI

`ProjectDeviceController.swift.snapshot` and `ProjectWorkspace.swift.snapshot` retain the previous Flutter/Expo controller and workspace for future design/reference work. They are excluded from SwiftPM and the universal application build. Their dependencies and API contracts may change; restoring this UI would require integration work.

The active app manages server/device profiles and streaming only. Server-side project operations remain in Go behind `OKESTRA_ANDROID_DEVELOPMENT_ENABLED=1` on both client and server. See `docs/archive/README.md` at the repository root.
