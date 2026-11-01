# Migration from combined Okestra

The standalone Device service uses a different binary, account, token, listener and data directory. Installing it does not migrate or delete the old service's data. Plan the cutover before updating a combined server to Docker-only Okestra.

## Mac

1. Quit the old Device app and disconnect its remote ADB bridge with the old `okestra android disconnect` command.
2. Keep a backup of `~/.okestra/config.json` and `~/Library/Application Support/Okestra`. These remain owned by the old installation; do not delete them.
3. Install the new Device app and `okestra-device` helper. Pair using the new Device server URL (normally port 8089) and the new token. Profiles live in `~/.okestra-device/config.json`; they are intentionally not copied from Docker profiles.
4. Physical phones can be used immediately through **This Mac**. Reinstall platform tools with the Device installer, or use existing Android SDK tools from PATH.
5. To retain saved developer presets and other Device support files, copy the `Device` subdirectory of `~/Library/Application Support/Okestra` into `~/Library/Application Support/Okestra Device`, with both app versions closed. Keep recordings and exported review bundles in their existing locations; they can be reopened directly. The application bundle identifier is retained so existing app preferences continue to apply.

## Linux emulator host

1. Back up `/etc/okestra`, `/var/lib/okestra/android`, `/var/lib/okestra/.android` and any external Android SDK/AVD paths. Save the old systemd unit and Android drop-in configuration.
2. Stop the managed emulator through the old client, disconnect clients, then stop the combined service during the migration window. Never let both services start emulators on the same ADB/emulator ports.
3. Install the standalone Device service. Its installer creates a separate `okestra-device` account, configuration and token. Use a different listener, normally `PRIVATE_IP:8089`.
4. For a fresh emulator, run the standalone Android setup script. To preserve existing guest data, copy the backed-up Android manager state and `.android` directory into the corresponding locations under `/var/lib/okestra-device` while both services are stopped. Copy the SDK into a dedicated writable Device location, or install a fresh SDK. Set ownership of copied Device files to `okestra-device:okestra-device`. Update absolute SDK/AVD paths in the copied AVD `.ini` and `config.ini` files. Inspect saved profiles for absolute AVD paths as well. Do not share a writable AVD between accounts.
5. Configure the new environment with `OKESTRA_DEVICE_ANDROID_ENABLED=1`, the new `ANDROID_HOME`, `ANDROID_USER_HOME=/var/lib/okestra-device/.android`, and `HOME=/var/lib/okestra-device`. Use `setup-android-server.sh --sdk PATH` to configure KVM membership and the SDK write-access drop-in. GPU settings use `OKESTRA_DEVICE_ANDROID_GPU`; archived development opt-in uses `OKESTRA_DEVICE_ANDROID_DEVELOPMENT_ENABLED`. Existing legacy `OKESTRA_FLUTTER_BIN` remains supported within that opt-in.
6. Start Device, pair the Mac with its new token, and verify profiles, emulator launch, saved guest data, video, input and ADB access.
7. Disable Android in the old service environment and remove its Android-only systemd drop-in after saving a backup. Upgrade Okestra to the Docker-only build and restart it. Docker continues on its existing listener and credentials.

The source extraction does not perform this live migration. Until acceptance passes, retain all backups. For rollback, stop the standalone Device service before restoring and restarting the old combined service and client.
