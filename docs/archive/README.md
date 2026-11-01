# Archived remote project workflows

This release focuses on remote Android emulators. Local Flutter, Expo development builds and other Android tools can use the tunneled ADB device. The Mac Device app has no project manifest, project selector, Develop section, source sync or framework-specific app actions. Okestra Menu keeps its existing Docker project tools; its Android controls are device-only.

The earlier implementations are retained in `internal/android`, `internal/client` and `internal/agent`, including their regression tests. Remote project mutation routes return HTTP 410 by default, and the CLI blocks their commands before contacting the server. Existing project files, mirrored source, caches, Flutter/Node installations and AVD data are left intact. Cleanup commands (`stop`, `unwatch`, logs) remain available for previous sessions.

For deliberate internal experimentation only, set `OKESTRA_ANDROID_DEVELOPMENT_ENABLED=1` in **both** the client environment and `/etc/okestra/okestra.env` on the server, then restart the service. This restores the archived CLI/API workflows, not the removed Mac UI. The normal Android installer explicitly sets this flag to `0` and does not install Flutter or Node. Provision archived toolchains separately if you opt in.

Reference guides from before the change:

- [Remote Android and Flutter projects](android-project-workflows.md)
- [Expo server builds](expo-project-workflows.md)

The previous Mac project controller and workspace are preserved as `.snapshot` source references in `apps/okestra-device/Archive`. They are excluded from the native build; they are not a second supported application or an automatically restorable UI.
