> **Archived reference.** Remote project builds are disabled by default. The current product offloads Android emulators; use local build tools. See [the current device guide](../android.md) and [archive notes](README.md).

# Okestra Device: Flutter and remote Android

Okestra Device is a custom native macOS app with embedded H.264 video, touch/drag/scroll, keyboard input, Back/Home/Recent Apps, rotation, clipboard actions, screenshots, reconnect controls and Flutter commands. It uses Apple's video decoder and bundles the pinned scrcpy 3.3.4 Android capture component. It does not open scrcpy's desktop window or require SDL/FFmpeg/Homebrew. Capture uses selectable Responsive, Balanced, Smooth (up to 60 fps), or Adaptive profiles; audio is disabled.

The Linux server runs Flutter, Java, Android SDK, the emulator and your debug app. Your Mac runs Okestra Device/Menu, the CLI, and Google's small Android platform-tools package. Local Flutter and Android Studio are optional for editor features; server builds do not require them on the Mac. The remote device appears in the Mac's local `adb devices` through an authenticated Okestra tunnel.

## Install from the packages built for this change

These changes are not in the public latest release until published. Use the `dev-android` archives in `dist/` for initial testing, with matching server and Mac packages. The server currently targets **x86_64 Linux with KVM**, and the apps support Intel and Apple Silicon Macs with macOS 13 or later.

### Linux server

Copy `okestra-service_dev-android_linux_amd64.tar.gz` to the server, extract it, enter the extracted folder, and run:

```sh
sudo ./install-android.sh
```

Automatic dependency installation supports Ubuntu/Debian, with Python's safe tar extraction support required (Ubuntu 24.04+ recommended). The installer asks for the private server address on first setup, installs the service, downloads Flutter stable, Node LTS/npm and Android command-line tools from their official manifests, verifies the published checksums, reviews SDK licenses interactively, installs Android API 35/Google APIs and emulator packages, creates `okestra-pixel`, configures KVM permissions, and checks acceleration. It sets the service environment and systemd SDK write permissions, then restarts Okestra. If Android activation fails, it restores the prior service environment and SDK write permissions. Keep the printed server URL and token private for pairing your Mac.

Tools live under `/var/lib/okestra`; the downloader runs as the `okestra` account. Existing tools, AVDs, pairing tokens and Docker settings are preserved. Existing Flutter installations are not silently upgraded. Downloads use staging directories and checksums; interrupted SDK package installation can be retried by running the same command. Incomplete manually installed tool directories produce an actionable error instead of being overwritten. The installer may install Docker if it is missing, because the existing service also provides Docker workflows.

KVM must be available before installation. For a VM, enable nested virtualization in its host first. Keep the service on a routed private network or HTTPS. Measure actual server RAM, CPU, storage, graphics support and network performance before sizing it for daily use; Gradle, emulation and backend containers share resources.

### Mac

Extract the matching Mac archive and double-click **Install Android.command**, or run:

```sh
./install-android.sh
```

The wizard installs the CLI and **Okestra Menu.app** plus **Okestra Device.app** into `~/Applications`, asks before downloading Google's platform tools, verifies the official manifest checksum, and guides pairing with the server URL/token. The tools go into `~/Library/Application Support/Okestra/platform-tools`. No Homebrew is needed. The apps bundle their matching CLI so they can still run if your terminal PATH contains an older Okestra binary. Quit and reopen apps after updates.

The developer archives are locally ad-hoc signed, not Apple notarized. macOS may require Finder → right-click → Open for downloaded builds; do not disable Gatekeeper globally. Developer ID signing and notarization are a later release credential step, not something the build scripts pretend to perform.

## Expo development builds

Expo development builds are supported through the same remote device and Mac apps. Fresh server setup includes Node/npm; existing servers can run `sudo ./setup-android-server.sh --expo`. See [Expo setup](expo-project-workflows.md) for framework configuration, builds, Metro, source sync, and environment variables. Expo Go and bare React Native are excluded.

## Start a Flutter project

From the Flutter project directory containing `pubspec.yaml`:

```sh
okestra android doctor
okestra android init --avd okestra-pixel
okestra android start
okestra android status
# Wait until Device is ready.
okestra android view
```

`init` creates `okestra.json` only if it does not exist. To add Flutter to an existing Docker project, add:

```json
{
  "name": "my-flutter-app",
  "android": {
    "path": ".",
    "avd": "okestra-pixel",
    "target": "lib/main.dart"
  },
  "services": {}
}
```

`android.path` may select a subfolder inside the project. Use different project names for unrelated checkouts; names identify server workspaces. Docker services can occupy `services` as usual and keep their existing commands.

In **Okestra Menu**, choose the folder containing the manifest. Its Android card opens **Okestra Device** and provides device/app commands. In **Okestra Device**, the live screen is centered in a hardware frame beside a native SwiftUI sidebar. The workspace keeps native window controls without a title or toolbar strip; drag the empty canvas to move it, and use **Cmd-W** to close the window. The sidebar has a native resizable divider and can be collapsed. **Device** contains measured stream FPS/bitrate, workspace appearance, frame finish, scale, view-only mode and display dimensions. **Develop** contains Flutter/Expo actions, source sync, logs and activity. The tray beneath the phone has Back, Home, Screenshot, Reload, Rotate and additional navigation/clipboard actions. Use **Control-Cmd-S** to hide the inspector or **Shift-Cmd-T** to open a separate Device Tools window. Choose a project, start the emulator from the session menu, and connect. If the manifest is missing, the inspector offers project configuration with the installed AVD name. Pair the server through the installer first.

The viewer automatically reconnects with increasing delays up to five consecutive failures. Reconnect explicitly after fixing a missing dependency. Mac sleep closes capture; wake attempts reconnection if the viewer was connected. Closing the viewer cleans up its capture sockets, ADB forward, and capture process, while retaining the remote Flutter session and shared Okestra ADB tunnel. Use explicit Stop/Disconnect commands to release those resources. The **Logs & diagnostics** menu under Develop exposes diagnostics and recent app/device/sync logs. Viewer capture output is in `~/Library/Logs/Okestra/device-capture.log`.

## Develop

Use the **Develop** tab’s **Run app**, **Reload**, **Restart**, and **Sync on save** controls, or:

```sh
okestra android run
okestra android logs
okestra android watch
```

Run synchronizes source and starts a supervised server-side Flutter debug process. It returns before compilation finishes; inspect app state and logs for build failures. Dart reload preserves state; restart resets Dart state. Native Android, plugin and dependency changes require stopping sync, stopping the app, and running it again. Watch pauses automatic reload after detecting those changes and records the rebuild notice in **Sync logs** or `okestra android watch-logs`.

Click/drag touches the screen; scroll gestures become swipes. Escape/right-click goes Back. Enter, Backspace, Tab and arrow keys map to Android keys. Text typing uses Android text injection; use Cmd-V or **Paste** in Device Tools for Unicode/emoji that Android's keyboard mapping cannot inject. **Copy device text** explicitly copies the selected/device clipboard to your Mac; clipboard changes are not silently synchronized. The viewer supports a single touch pointer; multi-touch, audio, recording and physical-device management are outside this initial release.

`okestra android connect` exposes the device without opening a viewer. `adb devices` should report `127.0.0.1:<allocated-port>` as `device`. Local Flutter can discover that serial if installed, but running local Flutter consumes your Mac's CPU; use Okestra Run for server builds. Do not run competing Flutter sessions on the same app. If your shell sets `ADB_SERVER_SOCKET`, unset it for your own ADB/Flutter commands. On Linux, `android view-scrcpy` remains an optional external-client fallback.

## Reliability and boundaries

One trusted developer, one server-managed emulator at ports 5554/5555, and one active Flutter workspace are supported. Okestra refuses to occupy another emulator's ports, refuses to stop a device with an active Flutter session, restricts tunnel access to the managed emulator's loopback ADB transport, and requires the normal server token. The emulator's unattended `-skip-adb-auth` setting is scoped by that host/private-tunnel trust boundary. This is not multi-user isolation.

Source sync is one-way from the Mac. It uploads a complete bounded snapshot on content change, atomically replaces individual files, removes previously uploaded deleted files and preserves server-generated caches. It is not a delta-transfer protocol or an all-files transaction. Upload limits are 200 MiB, 32 MiB per file and 20,000 regular files. Symlinks, `.git`, `.dart_tool`, builds, `.gradle`, `.env*`, keystores, Android local SDK properties, Pods and node_modules are excluded. Use `.dockerignore` for other private files; the default deny list is not a complete secret scanner. Do not edit the server mirror. Generated lockfile changes are not copied back, so maintain and commit the lockfile locally.

Process state and recent bounded logs are in memory; source, caches and AVD data persist on disk. A normal service shutdown stops process groups, and Linux guards direct children against parent death. After a restart, start the device and run again; sessions do not automatically resume. Background tunnel/watch controls and logs are in `~/.okestra/android`. If a Mac tunnel is offline after a route change, disconnect and reconnect. Disabling Android in the server environment and restarting preserves workspace data.

The Android guest's `localhost` is the guest; `10.0.2.2` reaches the Linux host. Docker service DNS names are not available in Android. Configure your app's API URL to reach the backend through a Linux host endpoint. Mac-only services are not automatically reverse-tunneled.

## Stop

```sh
okestra android unwatch
okestra android stop
okestra android disconnect
okestra android device-stop
```

Stop the app before the device. Closing the viewer or menu alone does not stop background sync or the shared ADB tunnel. Use `journalctl -u okestra-service` for service/setup errors.

## Existing server tools / source builds

If Flutter and SDK tools already exist in dedicated directories under `/opt` or `/var/lib/okestra`, configure them without downloading again:

```sh
sudo ./setup-android-server.sh /opt/flutter /var/lib/okestra/android-sdk okestra-pixel
```

Both directories must be writable by `okestra`; avoid a personal SDK under `/home` or `/root`, which systemd ProtectHome hides. Other project-specific Android SDK/NDK versions can be installed into the same SDK as that account. Existing Flutter versions are preserved; upgrade deliberately.

From source, run `make build`, `make device`, and `make menubar` on the Mac, or `make dist VERSION=dev-android` for packages. Source builds require Go/Xcode command-line tools; installed users do not need them. `okestra upgrade` refreshes both complete app bundles when a future published release contains them.

## Verification before daily use

Automated coverage checks input/video packet bounds, UTF-8 and coordinate handling, a real H.264 decoder fixture, socket fragmentation/cancellation, source confinement and deletion, process lifecycle, authenticated ADB bridging, archive safety and tool download selection/checksums. Native compilation, package integrity and installer syntax are also checked.

Actual Linux SDK installation, KVM/emulator boot, Android video encoding, phone input, app plugins, API access and end-to-end latency require the next real-server test. Verify boot → connect → run → edit/reload, deliberately break/fix a build, reconnect after a network drop, close/reopen the viewer, and restart the service. A passing fixture test is not evidence that a physical server has passed those checks.

### Display and workspace appearance

The viewer reads the Android model, AVD name and active `wm size` on connection. Its screen uses the guest’s native aspect ratio, including display-size overrides; the encoded video fits inside that area without stretching. The workspace uses a Pixel 7-style presentation skin with slim bezels and a centered camera. It keeps the guest’s actual display proportions; the skin does not change the AVD hardware or resolution. The default `okestra-pixel` AVD still supplies a 16:9 display. Changing the finish or hiding the frame affects only the viewer; it never changes the emulator’s resolution.

Liquid Glass uses the native SwiftUI API on macOS 26 and later, with a translucent material fallback on macOS 13–15. Workspace light/dark mode affects Mac controls, not Android’s theme. Reduce Transparency respects the Mac accessibility setting and also has a workspace override. The frame-rate graph measures decoded frames submitted for display, with incoming FPS shown separately. Bitrate measures encoded video bytes received by this viewer; they are not remote CPU, memory or total network-usage measurements. Static screens can correctly report zero FPS.

## Stream performance

The **Device → Stream performance → Stream profile** menu selects **Adaptive** (the default), **Responsive** (1024-pixel maximum edge, 30 FPS ceiling, 2 Mbps), **Balanced** (1280, 30 FPS, 4 Mbps), or **Smooth · 60 fps** (1280, 60 FPS, 6 Mbps). These are capture limits, not guaranteed minimum frame rates. Profile selection persists on the Mac. The guest resolution, Android app, Metro/Flutter process and shared ADB tunnel are preserved when capture reconnects to apply a profile. A profile change briefly interrupts video/input while the capture connection restarts.

Adaptive starts at Balanced. Four consecutive active measurement windows showing more than 100 ms relative backlog growth, 65 ms Mac UI wait, 30 ms average decode time, or more than 20% decoded frame replacement switch to Responsive. At least 45 healthy active windows and a 60-second cooldown allow recovery to Balanced. Idle screens do not trigger adaptation or recovery. Adaptive does not automatically select 60 FPS. Network capacity and Android software rendering/encoding can still limit performance.

H.264 decode runs on the capture worker through VideoToolbox, preferring hardware decoding with software fallback. All compressed reference frames are decoded. A single-slot mailbox replaces stale *decoded* frames while the UI is busy, and the display renderer is checked for backpressure before enqueuing. There is no unbounded frame queue or synchronous wait for the main thread per video frame. Local sockets use TCP_NODELAY. Capture timestamps are retained for estimating delay growth; the UI explicitly reports this as **Backlog growth**, not total network latency. **Decode / UI wait** reports average local decode time and maximum delivery wait within the sampling window. **Mac decoder** reports the actual decoder property when available.

### Optional Linux graphics acceleration

A service built from this revision accepts `OKESTRA_ANDROID_GPU=swiftshader|auto|host|software|lavapipe|swangle` in `/etc/okestra/okestra.env`. The compatible default remains `swiftshader`; `android status --json` reports the configured mode in `checks.graphics`. Unknown values fail before starting the emulator. Existing server setup preserves this setting. The Mac streaming improvements work with the existing server without changing this setting.

To try hardware graphics after updating the Linux service binary, stop source sync and the app, then stop the emulator using the normal Okestra controls. On the server, run `lspci -nn | rg -i 'vga|3d|display'` (or grep if rg is unavailable) and inspect `/dev/dri`. Confirm that the `okestra` service account has access to the GPU render node and the required host drivers; group membership and driver setup depend on the server. Set one `OKESTRA_ANDROID_GPU=host` line using `sudoedit /etc/okestra/okestra.env`, restart `okestra-service`, and start the emulator again. Restore `swiftshader` and restart if host graphics are unsupported. `auto` delegates renderer selection to the emulator. A GPU advertised by a cloud provider is not sufficient proof that the emulator or Android encoder can use it. On headless Linux, host rendering also needs compatible EGL/GLES libraries and a supported graphics/display backend. Inspect device logs for the actual Graphics Adapter: `host` in `checks.graphics` reports the requested mode, not proof of hardware rendering. A log naming SwiftShader or llvmpipe is still software rendering; restore the compatible default if hardware initialization fails. KVM CPU acceleration and GPU rendering are separate. Service restart stops supervised sessions; it does not delete projects or the AVD.

### Compare performance

Use the same animated Android screen or repeatable scrolling sequence, device resolution, Wi-Fi placement and route. Compare Responsive, Balanced and Smooth while watching **Received**, displayed frame rate, **Decode / UI wait**, and **Backlog growth**. Static screens legitimately transmit few or no frames. Low incoming FPS with fast local decode points upstream (app rendering, encoder or transport); a high received rate with frame replacement/UI wait points to local presentation pressure. A low received rate alone does not identify which upstream stage is responsible. GPU mode changes require a separate server test.
