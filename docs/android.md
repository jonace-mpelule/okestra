# Okestra Device: remote emulators and physical Android phones

Okestra Device is a native SwiftUI/AppKit Mac viewer for Android emulators hosted on your Linux server and physical Android phones connected directly to your Mac over USB or Wi-Fi. It includes an interactive H.264 screen, device profiles and skins, keyboard/touch/scroll input, navigation, rotation, screenshots, clipboard actions and measured stream performance. The lightweight Mac client uses Apple's video decoder and bundles the pinned scrcpy 3.3.4 Android capture component; it does not launch an external scrcpy window or require SDL/FFmpeg/Homebrew.

The Linux server runs the Android SDK, Java and one KVM-accelerated emulator. Your Mac runs the viewer, matching CLI and Android platform tools. Your local build tools compile the app and deploy to the tunneled ADB device. **Flutter and Node are not required on the server.** The viewer does not require `okestra.json` or any project folder. Earlier remote Flutter/Expo builds and sync are [archived](archive/README.md).

## Install the matching packages

Use matching server and Mac packages from the local `dist/` directory until this change is published. The Android host must be **x86_64 Linux with `/dev/kvm` available**; enable nested virtualization first when applicable. Mac apps support Apple Silicon and Intel on macOS 13+. Liquid Glass uses the native API on supporting macOS versions with a material fallback on older releases.

On Ubuntu/Debian, extract the Linux service package, enter its directory, then run:

```sh
sudo ./install-android.sh
```

The installer asks for a private server address on first setup, installs service dependencies and Java, downloads Android command-line tools from Google's manifest with checksum verification, reviews SDK licenses, installs platform tools/emulator and the Android 35 Google APIs x86_64 image, creates the initial Pixel 7 AVD and enables Android in the service. It configures KVM membership and SDK write access. It uses `qemu-system-x86` rather than the virtual `qemu-kvm` package. Service configuration is restored if activation fails.

Downloads run as `okestra`, under `/var/lib/okestra`, from an accessible working directory. This avoids the earlier failure caused by inheriting `/home/dev/okestra-android-setup` when that directory is private. The installer preserves existing tools, AVDs, pairing credentials and Docker configuration. Re-running it does not replace an existing AVD. Flutter/Node installations from an earlier release are retained but unused. Docker may be installed if absent because the same service supports the separate Docker product.

For an existing SDK:

```sh
sudo ./setup-android-server.sh --sdk /var/lib/okestra/android-sdk
```

For an existing Android-enabled server, updating the service binary is sufficient to enable device profiles; the new service imports installed AVDs automatically. Installing a matching Mac client does not require re-pairing.

On the Mac, extract the matching package and double-click **Install Android.command**, or run:

```sh
./install-android.sh
```

The wizard installs both Mac apps into `~/Applications`, installs the CLI, offers checksum-verified Google platform tools and guides server pairing. Platform tools live at `~/Library/Application Support/Okestra/platform-tools`. Both apps bundle their matching CLI so an older terminal installation cannot change their behavior. Quit and reopen apps after updating.

Developer packages are ad-hoc signed, not Developer ID signed or notarized. Downloaded builds may require Finder → right-click → Open. Do not disable Gatekeeper globally.

## Choose a device

Open **Okestra Device**. Use the compact device bar at the top-left of the canvas:

1. Open **Device source**, select **Server devices**, then choose a paired server from that source menu.
2. Open the device-name dropdown to choose an existing profile, or use the adjacent **Device options → New profile…** menu while stopped.
3. Choose **Device options → Start device**; the viewer connects automatically. Allow time for its first boot.

New profiles support Pixel 7 and Pixel 9 hardware templates on Android 35, with names, **1–8 CPU cores** and **1536–8192 MiB RAM**. The editor offers common RAM sizes; the API/CLI accepts 256 MiB steps. Profiles have separate AVDs and Android app/data storage. Rename or change CPU/RAM with **Device options → Edit profile…** while stopped. Display identity, resolution and AVD stay attached to that device. Existing installed AVDs appear without recreating or wiping them.

**One emulator runs at a time per server.** Stop it before creating/editing profiles or starting another device. Selecting another profile alone does not switch the running emulator; the canvas label and frame continue to describe the active device. There is no delete/wipe action in this release. The saved selection is remembered per server. At most 24 newly saved profiles are supported; imported installed AVDs remain visible.

CPU/RAM settings allocate server resources; a Pixel name does not reproduce that physical phone's processor speed. Actual performance depends on the server. Each supported model has its own frame proportions, with the guest's actual screen aspect ratio preserved during streaming, scaling and rotation. Existing AVDs without a supported model use a presentation skin and retain their actual screen ratio.

The viewer retains native traffic lights without a title strip, the resizable/collapsible Swift sidebar, Liquid Glass controls, workspace appearance, frame finish and scale controls. The compact tray contains Back, Home, Screenshot, Recent Apps and Rotate. Additional actions include clipboard/paste, power, volume and navigation. **Control-Cmd-S** toggles the sidebar; **Shift-Cmd-T** opens Device Tools. Okestra Menu's Android card opens the viewer and provides ADB connection, logs and setup diagnostics, independent of its Docker project selector.

The source menu, device switcher, refresh and connection-options menu are grouped at the top-left of the canvas. Connect/disconnect, Wi-Fi setup, reconnect and server device actions live in that options menu. The sidebar focuses on stream performance and appearance. Rotating uses the last displayed video frame for a spring rotation/resize, then fades into the newly oriented live video. It follows actual stream orientation changes, supports framed and frameless views, briefly suspends touch input during the transition, and uses a short fade when macOS Reduce Motion is enabled. Apps/devices that retain their orientation do not trigger a fake rotation.

The top-right canvas toolbar adds **sidebar**, **Focus mode** and **more options**. The **zoom out**, **fit**, **actual size** and **zoom in** controls sit at the bottom-right of the canvas. Fit follows the available canvas; actual size maps one received video pixel to one Mac display pixel, accounting for Retina scaling. Zoom buttons change the displayed scale by 5 percentage points per click (for example, 91% to 96%). Zoom changes presentation only, not capture quality or Android display settings. The zoom percentage is shown above the bottom-right zoom controls. **Option-drag on the video** pans an enlarged device; **Option-scroll** pans the canvas, while ordinary drags and scrolling continue to control Android. Fit recenters the device. The navigation tray floats at the bottom. The phone uses the full canvas and can pan beneath the floating controls without being clipped into a shorter area between them. When the sidebar is hidden, the header leaves room above it for the native traffic lights. On narrower windows, the source becomes an icon and device names truncate; actual-size and Focus mode actions remain available in the toolbar menu. At the narrowest widths, the compact toolbar wraps beneath the device bar. Sidebar, zoom out, fit and zoom in stay directly accessible.

**Always on Top** pins the viewer above other app windows, including in Focus mode. Use the pin button, toolbar menu, Window menu or command palette. Your pin preference is remembered. A battery badge beside the device name shows the connected device's level and charging state, refreshed every 30 seconds; unavailable readings are hidden.

**Screenshots** capture the full Android screenshot, independent of stream downscaling. The camera button or **Capture screenshot** command saves a PNG automatically to `~/Pictures/Okestra/Screenshots`, plays the macOS shutter sound and animates a thumbnail into the bottom-right corner. The thumbnail stays for five seconds after arriving: drag the image into another app, click **Copy** to put the image on the clipboard, or leave it alone. When the five seconds expire, the thumbnail fades and slides out. Click the thumbnail to open an editor overlay covering the current workspace; opening it cancels the expiry timer. The editor has freehand drawing, arrows, outline boxes, solid black redaction, text labels, colors, Undo/Redo, Save and Copy. Resize the window without shifting annotations. Save creates a separate edited PNG in the screenshots folder; Copy puts the edited image on the clipboard. Both exports flatten annotations at the original screenshot resolution, including opaque redaction pixels. The original capture remains saved. Use Done or Escape to return to the device; unsaved edits offer Save, Cancel or Discard. The same protection applies to closing the window or quitting the app. Select annotations to move, restyle or delete them; double-click a text annotation to edit it. Line weights and text sizes are adjustable. Native Undo/Redo applies to drawing, moving, styling and deletion. Zoom with the footer controls or trackpad; hold Space and drag to pan. Use Cmd-0 for Fit and Cmd-1 for Actual Size. Cmd-S saves, Shift-Cmd-S saves a separate copy, and Cmd-C copies when the canvas is focused. Repeated Save updates the same edited copy. PNG rendering and file writing run away from the UI thread, and save failures retain your edits. Open an existing PNG with **File → Open Screenshot…** (Shift-Cmd-O) or the command palette. Editor regression checks run with `./scripts/test-device-editor.sh`; they use a temporary screenshot directory and a private test clipboard, with no connected device required. Right-clicking the thumbnail also offers Edit, Copy, Show in Finder and Dismiss. Dismissing the thumbnail never deletes the saved file. Reduced Motion uses fades instead of flight or slide animations.

**Focus mode** turns the current viewer into a compact, resizable device window beside your IDE. The sidebar, dotted workspace, connection bar, zoom controls and bottom tray are hidden; the device fits the available window without changing capture quality or reconnecting. A small native title strip remains for moving/closing the window and returning to the workspace. Use **Shift-Cmd-F**, the return icon, or **Escape** to exit. The normal window frame, sidebar choice and canvas zoom are retained; focus window sizing is not saved over the workspace's window position. Orientation changes resize the focus window to suit the device. Entering Focus mode from macOS fullscreen first returns to the desktop. Opening Developer tools returns to the workspace. macOS fullscreen remains available through the native green window button.


## Connect a physical Android phone

Select **Device source → This Mac** in the device bar above the phone. This mode needs Mac Android platform tools and the bundled capture component; no paired Okestra server is required. Android and your apps run on the phone. The Mac receives video and sends input directly over USB or your network.

### USB

1. Enable **Developer options → USB debugging** on the Android phone.
2. Connect it to the Mac with a data-capable cable. Unlock the phone and approve its debugging authorization prompt.
3. Click **Refresh phones**, choose the phone and click **Connect**. Choosing an authorized phone also connects it immediately.

Unauthorized and offline phones remain listed with guidance. If authorization never appears, check the cable, USB connection mode and debugging settings. Local emulators and Okestra's loopback ADB tunnel are excluded from this phone list.

### Wi-Fi (Android 11 or newer)

1. Put the phone and Mac on the same network. Enable **Developer options → Wireless debugging** on the phone.
2. Select **This Mac**, then use the adjacent **Device options → Connect over Wi-Fi…** menu in Okestra Device.
3. On the phone, tap **Pair device with pairing code**. Enter that dialog's **IP address and pairing port** and **six-digit code** into step 1 of the Mac sheet, then click **Pair**. The code goes to ADB through standard input and is not saved in preferences or placed in process arguments.
4. Return to the phone's main **Wireless debugging** screen. Enter its **IP address and connection port** into step 2 of the Mac sheet, then click **Connect phone**. This port is different from the pairing port. The viewer connects once the phone is available; close the sheet with **Done**.

For an already paired phone, skip pairing and enter its current connection address. Android can change this port after wireless debugging or Wi-Fi restarts; reconnect using the new address. The app also lists wireless devices ADB has already discovered/connected. Pairing codes expire; generate a fresh code if pairing fails. Guest Wi-Fi, client isolation and firewalls can prevent devices on the same network from reaching each other.

Phones use the same quality selector, touch/keyboard/scroll controls, navigation, rotation, screenshots and clipboard actions. Capture limits do not change the phone's display resolution, density or system animations. Protected content can appear black; some manufacturers require an additional debugging/security option for input injection. Unlocking and initial authorization happen on the phone.

Switching sources or clicking **Disconnect** closes this viewer's capture/control session. It does not power off the phone, stop the server emulator, revoke ADB authorization or disconnect other development tools. **Phone options → Copy device serial** provides the explicit target for commands such as `adb -s SERIAL install app.apk` or `flutter run -d SERIAL`. The app remembers the source and chosen phone; it does not switch to another phone automatically if that device disappears.

## Developer tools

Open **Developer → Developer tools** (`Shift-Cmd-D`), use the hammer button in the expanded canvas toolbar, or choose **Developer tools** from its options menu. **Cmd-K** opens a compact floating command palette with up to six visible rows, arrow-key navigation, Return to run and Escape/outside-click to dismiss. Its height adapts to the search results. The compact tools panel uses a native section sidebar, app/log lists and grouped capture controls. Add deep links or port mappings with the **+** buttons; their forms open in popovers. App reset is in the app-actions menu. The tools use the explicitly connected device for USB, Wi-Fi and remote emulator sessions. Changing devices cancels in-flight tool commands and stops that device's logs/recording; commands never fall back to a default ADB target.

- **Apps:** drag APK files onto the canvas or tools panel, or use **Install APK** (`Cmd-I`). Installation keeps existing app data (`adb install -r`) and reports Android's installation errors. Signature mismatches do not automatically uninstall or reset an app. The searchable list shows user-installed package names. Select one to launch, restart, view its logs or clear its storage. Clear data requires confirmation in the UI and removes that app's sign-in and local data.
- **Logs:** start/stop Logcat, filter by the selected app's process IDs, severity and text, follow new messages, copy the visible filter, and clear the local buffer. Process IDs refresh while logging and Java crash process markers preserve exited-app stacks. Crash/ANR signals are listed in the panel; a canvas badge alerts you to new relevant signals while the panel is closed. Logging must be running to detect new crashes. Storage is bounded to 5,000 rows / 2 MiB; high-volume delivery is coalesced and reports skipped rows rather than flooding the UI. This is a live session buffer, not a persistent crash database.
- **Links & ports:** save named deep links with an optional target package. Save named device-localhost → Mac-localhost reverse mappings for Metro and local APIs. **Connect** applies a mapping; **Disconnect** removes that exact mapping; **Refresh connections** checks ADB's current state. Mappings are not automatically reapplied, and conflicting mappings are never silently replaced. Viewer disconnect does not remove mappings used by your development tools. Saved links/ports and selected apps are scoped to the physical serial or remote server/device profile, and stored privately in `~/Library/Application Support/Okestra/Device/developer-presets.json`.
- **Sidebar → Audio routing:** enable Android audio playback on the Mac, mute playback and adjust its volume. It uses the Mac's selected output device, including headphones. Enabling/disabling capture audio reconnects the stream, so this toggle is unavailable during recording; mute/volume changes are immediate and do not change the phone or recording volume. Audio starts off until enabled, and that choice is remembered. Android 11+ is required; unlock Android 11 before connecting. Device/app capture restrictions can produce silence or unavailable audio without stopping video. The pinned server sends 48 kHz stereo PCM, approximately 1.54 Mbps before transport overhead; this avoids an extra audio encoder/decoder dependency.
- **Capture → Recording:** use **Record screen** (`Shift-Cmd-R`); the recording saves automatically to `~/Movies/Okestra/Recordings`. It muxes the received H.264 stream without re-encoding the video; Android audio is encoded to AAC in the movie when routing is enabled and audio is available. Starting a recording requests a fresh keyframe; a 30-second timeout handles unavailable video. Static screens retain their final frame until Stop. Stop it from the panel, command palette, menu or canvas recording badge. Disconnect, quality reconnect and changing video dimensions finish the current recording; rotate first when you need a recording in another orientation. If storage cannot keep up, recording ends with a readable status instead of accumulating unlimited memory.
- **Recording review:** when a recording finishes saving, its preview animates to the bottom-right for five seconds, with an animated exit. Click it to open the video editor over the same workspace, or drag the saved movie into another app. Reopen it through **Capture → Review**, **Review latest recording** in Cmd-K, or **File → Open Recording…**. Scrub/play the video and add timestamped comments. **Annotate Frame** opens the existing drawing/box/redaction editor for that still; Save adds the PNG to the review. Frame markup does not alter the original movie. **Voice Note** records the Mac microphone at the current timestamp (permission is requested on first use), pauses movie audio and supports up to five minutes per note. Comments and attachments save beside the recording in a `.okestra-review` folder. Closing a review saves an unposted comment and finishes any voice recording; save failures retain the editor. Live Android playback is temporarily muted while reviewing, then restored. **Save Video…** copies the original movie; **Export for Agent…** creates a ZIP containing the original video, `Review.md`, `review.json`, annotated frame PNGs and voice notes. The annotations are portable sidecar files, not burned into a re-encoded video. Run `scripts/test-video-review.sh` for movie/preview/editor/export checks without microphone access.
- **Bug reports:** optionally add notes and include the most recent finished recording from this device, then export a ZIP (`Shift-Cmd-B`). It contains session/device details, a native Android screenshot, the currently filtered buffered logs, selected-app package details and notes. Missing optional artifacts are described in the archive's README. It does not include Okestra pairing credentials/configuration. Start logs before reproducing a problem and stop an active recording before exporting it.

The command palette includes app launch/restart, installation, logs, recording, report export, audio routing/mute, saved links and port mappings, plus screenshot/sidebar/reconnect actions. Screenshots and device controls remain available while developer tools are closed.

## CLI without a project

These commands work from any directory:

```sh
okestra android servers
okestra android profiles --profile SERVER
okestra android profile-create --profile SERVER --name 'Pixel 7 Daily' --hardware pixel_7 --cores 2 --memory 2048
# Copy the returned id, then:
okestra android start --profile SERVER --device PROFILE_ID
okestra android status --profile SERVER
# Wait for Device: ready
okestra android view --profile SERVER
okestra android connect --profile SERVER
adb devices -l
```

`--profile` is the paired **server** name; `--device` is the saved **device profile ID**. If only one device profile exists, `android start` can choose it automatically. `--avd NAME` remains available for a manually managed installed AVD. Saved-profile starts apply the saved CPU/RAM settings; raw `--avd` starts use the AVD's own configuration. Do not specify both options.

Update an existing profile while stopped:

```sh
okestra android profile-update --profile SERVER --device PROFILE_ID --name 'Pixel 7 Daily' --cores 4 --memory 3072
```

The authenticated service stores profile metadata atomically at its data root under `android/device-profiles.json`. Names/resource changes do not create a new AVD or erase installed apps. AVD files use the configured `ANDROID_AVD_HOME` or `ANDROID_USER_HOME/avd`.

## Local development

`adb devices -l` should show `127.0.0.1:<allocated-port>` as `device`. Use that serial as the target in your editor, Android Studio, local Flutter or an Expo development build. Use the same local Android platform-tools/ADB server as your development tools. Okestra removes `ADB_SERVER_SOCKET`, `ANDROID_SERIAL` and `ADB` overrides from its own subprocess environment; clear conflicting overrides in your shell as needed.

For local Flutter, discover the device with `flutter devices` and run `flutter run -d SERIAL` from your app. Flutter/Dart compilation remains on your Mac; the Flutter engine and app execute inside Android on the server. For local Expo development builds and optional Metro port reversal, see [Expo usage](expo.md).

The viewer opens the authenticated shared ADB tunnel automatically. Closing/disconnecting the viewer stops only capture and its private ADB forwards; it leaves the emulator and shared ADB tunnel available to local tools. Explicitly use `okestra android disconnect --profile SERVER` to remove that Mac connection, and `okestra android device-stop --profile SERVER` to stop the emulator. Reconnect after a device restart/profile change if local ADB becomes offline. A service restart stops its managed emulator; profiles and Android data persist, but devices do not automatically restart.

The guest's `localhost` refers to Android; `10.0.2.2` reaches the Linux host. Your Mac's services are not automatically reachable from the guest. Use explicit `adb reverse`, an appropriate private network endpoint or your existing app tooling.

## Device network traffic

The sidebar's **Network** section shows a single duplex graph: **upload above the centre line**, **download below**, with distinct colours, current values in Mbps and a shared automatic scale. It keeps a rolling 60-second history and samples Android's device-wide byte counters once per second. This measures current network traffic, not the connection's maximum bandwidth; it includes local traffic, including mirroring over Wi-Fi. No speed-test traffic is generated.

The counter reader runs separately from capture, uses the explicitly selected device and ends on disconnect, device change or Mac sleep. The first reading establishes a baseline; a second reading produces the rate. Clock/counter resets and long gaps establish a new baseline rather than showing a spike. Offline, unsupported and failed readers show a waiting/unavailable state instead of invented zero readings. An unavailable reader can be retried from the section header. The same reader is used for USB, Wi-Fi and remote Android targets.

The small reader is bundled as `apps/okestra-device/Resources/okestra-network-monitor-v1.jar` and runs through the existing authorized ADB connection; it does not install an Android app. Its source is `apps/okestra-device/Android/NetworkMonitor.java`. The helper initializes the Android network service when required by newer platform versions. Normal viewer builds verify its embedded source hash and require no Android/Java tools. To rebuild after editing the Java source, run `scripts/build-network-monitor.sh` with a local Android SDK and JDK. Compatibility checks for the helper run with `python3 scripts/test_network_monitor.py`. The script accepts `ANDROID_SDK_ROOT`/`ANDROID_HOME` and `OKESTRA_JAVA`, `OKESTRA_JAVAC`, `OKESTRA_JAR`, `OKESTRA_ANDROID_JAR`, `OKESTRA_D8_JAR` overrides.

## Streaming and diagnostics

Choose Responsive (up to 24 fps), Balanced (up to 30 fps), Smooth (up to 60 fps), or Adaptive in the sidebar. Lower stream resolution/bitrate reduces transport and decoding costs; it does not resize the Android UI. Adaptive steps down under sustained video/decode backlog and steps back up after recovery. The player decodes away from the main UI thread and keeps only the latest decoded frame for presentation. Static Android screens intentionally produce fewer frames; a target FPS is a ceiling rather than a forced stream of identical images.

**Native** captures at the device's current display resolution with no configured FPS limit and a 40 Mbps H.264 bitrate target. It applies no adaptive quality reduction and disables scrcpy's automatic resolution fallback on encoder errors. Encoder alignment/hardware limits still apply; unsupported full-resolution capture fails rather than silently switching to a smaller stream. Native works with USB, Wi-Fi and server devices; it does not reset display overrides previously applied to an emulator. H.264 remains compressed, so Native is not lossless video. The Mac still fits the full-resolution stream into the viewer window. Actual FPS depends on device activity, encoder, connection and presentation capacity.

The sidebar reports measured FPS/bitrate with a compact **Quality** selector. **Stream details** expands the received rate, decode/UI wait, backlog and decoder readings. The top-left device bar contains the source/server and device selectors, refresh, and **Device options** for profile editing, connection controls, device details/ADB serial, **Viewer diagnostics**, **Device logs** and **Check setup**. The footer uses a soft native scroll-edge blur on macOS 26+, with a feathered material fallback on older versions, so sidebar content can scroll beneath the status. Capture output lives at `~/Library/Logs/Okestra/device-capture.log`; shared ADB state/logs live under `~/.okestra/android`.

The viewer retries a broken stream with increasing delays, bounded to five attempts, and reconnects after Mac sleep if it was connected. Fix missing dependencies and explicitly reconnect when needed. Tailscale may use a direct LAN path or a relay; measure its actual path before attributing FPS to Internet routing. Wi-Fi contention, server software rendering and guest workloads can still limit performance even over LAN.

KVM CPU acceleration and host GPU acceleration are separate. The default renderer remains `swiftshader` for compatibility. `OKESTRA_ANDROID_GPU` accepts the existing opt-in host/auto/software modes; do not assume an older Intel GPU supports Android's headless Vulkan/EGL requirements. Changing rendering modes requires stopping/restarting the emulator and testing the host.

## Trust and current limits

This release supports one trusted operator and one server-managed emulator, not multi-user tenant isolation. API/profile/tunnel access requires the normal pairing token. ADB is scoped to the managed emulator's loopback transport at server ports 5554/5555, and the Mac tunnel listens only on loopback. Keep the service on a private routed network or properly configured HTTPS; never publish unauthenticated ADB to the Internet.

Navigation, single-pointer touch, scrolling, keyboard, clipboard and screenshots are supported. Multi-touch, arbitrary Android-image downloads, profile deletion and concurrent managed devices are outside this release. Screen recording currently finishes at orientation/resolution changes rather than combining them into one movie. Audio availability depends on Android version and app/device capture policy. Physical phones connect directly to the Mac; server-attached phone management is not included. Existing framework integrations remain recoverable in the archive; enabling them deliberately does not restore their former Mac UI.
