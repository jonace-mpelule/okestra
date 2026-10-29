# Okestra Device: Flutter and remote Android

Okestra Device is a custom native macOS app with embedded H.264 video, touch/drag/scroll, keyboard input, Back/Home/Recent Apps, rotation, clipboard actions, screenshots, reconnect controls and Flutter commands. It uses Apple's video decoder and bundles the pinned scrcpy 3.3.4 Android capture component. It does not open scrcpy's desktop window or require SDL/FFmpeg/Homebrew. Capture is limited to 1280 pixels, 30 fps and 4 Mbps; audio is disabled.

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

Expo development builds are supported through the same remote device and Mac apps. Fresh server setup includes Node/npm; existing servers can run `sudo ./setup-android-server.sh --expo`. See [Expo setup](expo.md) for framework configuration, builds, Metro, source sync, and environment variables. Expo Go and bare React Native are excluded.

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

In **Okestra Menu**, choose the folder containing the manifest. Its Android card opens **Okestra Device** and provides device/app commands. In **Okestra Device**, choose a project, start the device, and connect. If the manifest is missing, the viewer offers to configure the project using the AVD name. Pair the server through the installer first.

The viewer automatically reconnects with increasing delays up to five consecutive failures. Reconnect explicitly after fixing a missing dependency. Mac sleep closes capture; wake attempts reconnection if the viewer was connected. Closing the viewer cleans up its capture sockets, ADB forward, and capture process, while retaining the remote Flutter session and shared Okestra ADB tunnel. Use explicit Stop/Disconnect commands to release those resources. View → More exposes diagnostics and recent app/device/sync logs. Viewer capture output is in `~/Library/Logs/Okestra/device-capture.log`.

## Develop

Use the viewer's **Run app**, **Reload**, **Restart**, and **Enable sync on save** controls, or:

```sh
okestra android run
okestra android logs
okestra android watch
```

Run synchronizes source and starts a supervised server-side Flutter debug process. It returns before compilation finishes; inspect app state and logs for build failures. Dart reload preserves state; restart resets Dart state. Native Android, plugin and dependency changes require stopping sync, stopping the app, and running it again. Watch pauses automatic reload after detecting those changes and records the rebuild notice in **Sync logs** or `okestra android watch-logs`.

Click/drag touches the screen; scroll gestures become swipes. Escape/right-click goes Back. Enter, Backspace, Tab and arrow keys map to Android keys. Text typing uses Android text injection; use Cmd-V or **Paste Mac clipboard** for Unicode/emoji that Android's keyboard mapping cannot inject. **Copy Android clipboard** explicitly copies the selected/device clipboard to your Mac; clipboard changes are not silently synchronized. The viewer supports a single touch pointer; multi-touch, audio, recording and physical-device management are outside this initial release.

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
