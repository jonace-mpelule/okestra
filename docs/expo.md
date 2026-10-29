# Expo development builds on remote Android

Okestra can build and run an Expo Android development client on the Linux server, with Metro also on the server. The existing Okestra Device app streams and controls the emulator. Your Mac edits source and sends source snapshots; it does not need Node, Expo, Flutter or Android Studio for this server-build workflow. Existing local-tool workflows targeting the tunneled ADB device remain available.

Only **Expo development builds** are supported here. The project must declare `expo`, `expo-dev-client` and `react-native` dependencies. Okestra never selects Expo Go and does not introduce a bare React Native runner or an EAS cloud-build dependency.

## Server setup

Install matching packages from `dist/`; the public release does not contain these changes until published. New `install-android.sh` server installations include checksum-verified Node LTS and npm alongside Flutter/Android tools. On an existing Android server, install the new service binary and then run from the extracted service package:

```sh
sudo ./setup-android-server.sh --expo
```

This installs managed Node/npm under `/var/lib/okestra/node` without replacing existing toolchains. It runs downloads/extraction as the service account, verifies the official Node SHA-256 manifest, and preserves an existing managed Node installation. Manual installations may instead set `OKESTRA_NODE_BIN` and `OKESTRA_NPM_BIN` in the service environment and restart the service.

A committed package-manager lockfile is required. npm is included in setup. pnpm, Yarn or Bun are supported when their matching executable is installed for the service account; use `OKESTRA_PNPM_BIN`, `OKESTRA_YARN_BIN` or `OKESTRA_BUN_BIN` if outside its PATH. Installing those optional managers is deliberate, not an unpinned download on every Run. Yarn requires the node_modules linker; Yarn PnP and workspace roots/dependencies outside the synchronized source directory are not supported in this initial integration.

## Project configuration

Ensure the project already has a compatible `expo-dev-client`, using the project's normal Expo installation workflow locally. Okestra does not change dependencies or lockfiles on your Mac.

From the project root:

```sh
okestra android init --framework expo --avd okestra-pixel
```

For an existing `okestra.json`, add/update its Android block:

```json
{
  "name": "my-expo-app",
  "android": {
    "framework": "expo",
    "path": ".",
    "avd": "okestra-pixel",
    "expo": {
      "package_manager": "npm",
      "port": 8081
    }
  },
  "services": {}
}
```

The default framework remains Flutter for older manifests. Expo uses its package entry point; `android.target` is a Flutter-only field. Omit `package_manager` to infer it from a single lockfile. Multiple package managers require explicit selection matching the package.json declaration. Use the project's installed version, especially for Yarn's v1 versus modern installation flags.

## Run and edit

```sh
okestra android start
okestra android status
# Wait for Device: ready.
okestra android view
okestra android run
okestra android logs
okestra android watch
```

Run performs these server-side steps:

1. Validate the Expo development-build project and lockfile.
2. Install locked dependencies (`npm ci --include=dev`, or the manager's frozen/immutable equivalent). Unchanged successful dependencies are cached.
3. Generate Android with Expo prebuild when Android sources were not uploaded.
4. Build/install using the project's local Expo CLI and `run:android --device emulator-5554 --no-bundler`.
5. Establish ADB reverse forwarding for the selected Metro port.
6. Run Metro with `start --dev-client --localhost --android`, explicitly targeting the installed development client.

All Expo commands use the local CLI from the installed dependencies; Okestra does not let npx silently fetch a different Expo version. Status moves through `installing`, `building`, `starting`, `running`, `needs_rebuild`, `stopping`, and `failed` as applicable. Running means Metro is serving; it does not certify that your application's first screen or backend requests succeeded. Both install and build stages have a one-hour deadline; Metro runs until stopped. Logs expose actual package/build/Metro failures.

Metro binds localhost, with the emulator reaching it through server-side ADB reverse. No public Metro endpoint or ngrok tunnel is needed. The app advertises the same selected port that was reverse-forwarded. Run fails clearly if the port is already occupied.

Enable sync on save from either Mac app, or use `watch`. JavaScript/TypeScript edits are synchronized atomically per file, and Metro handles Fast Refresh without an unconditional full reload. Run should finish before enabling watch: uploads are refused during dependency installation, prebuild, and native compilation, then the watcher retries. The source transfer is the existing bounded snapshot implementation, not file-delta synchronization. `node_modules`, `.expo`, generated builds, and other existing exclusions stay server-side.

## Rebuild, reload and development menu

The Mac apps show **Rebuild** for Expo instead of Flutter's **Restart**, and expose **Open development menu**. CLI equivalents:

```sh
okestra android reload
okestra android dev-menu
okestra android restart
```

Reload and the dev menu use Expo's version-2 Metro command WebSocket with an origin restricted to the localhost server. They require a connected development client; errors explain when the app has not connected yet. Reload may reset JavaScript state, whereas normal edits use Fast Refresh.

Rebuild stops the prior Expo session, synchronizes current source/settings, rebuilds the native client, and starts Metro again. Dependency/lockfile changes, Android edits, app configuration, Metro/Babel configuration, custom plugins, patches and local native modules mark the client as needing a rebuild. Reload refuses while native configuration is stale. Changes to native assets such as app icons/splash resources, or configuration loaded from arbitrary external files, may also require an explicit rebuild even if automatic detection does not identify them.

For Expo CNG projects whose Android folder is not uploaded, a rebuild uses clean Android prebuild in the server mirror. Generated Android edits there are intentionally disposable. If Android sources are checked in and uploaded, they are preserved and used directly; update those sources using your normal local prebuild/native workflow when changing config plugins. No server-generated native files or lockfile changes are copied back to your Mac.

## Environment variables

Source sync omits `.env*` by default. To explicitly supply launch variables, use a path relative to `android.path`:

```json
{
  "android": {
    "framework": "expo",
    "path": ".",
    "avd": "okestra-pixel",
    "env_file": ".env.development",
    "expo": {
      "port": 8081,
      "environment": {
        "EXPO_PUBLIC_API_URL": "http://10.0.2.2:3000"
      }
    }
  }
}
```

The env file stays on the Mac; its values travel in the authenticated launch request and are passed to dependency/build/Metro processes. Inline environment entries override the env file. Okestra does not print these values itself, but project/package scripts can, so handle credentials accordingly. Expo's `EXPO_PUBLIC_*` variables are embedded in client code and are not secrets. Do not upload real registry tokens in `.npmrc`; use appropriate variable references and explicit launch values instead.

Okestra manages SDK/ADB settings, PATH, HOME, CI, NODE_ENV, NODE_OPTIONS and packager addressing, so these cannot be overridden by the project environment. Environment changes take effect on Rebuild. The watcher detects changes to the explicit launch environment and reports the rebuild requirement. Launch environment size is bounded.

## Stop and recover

```sh
okestra android unwatch
okestra android stop
okestra android disconnect
okestra android device-stop
```

Stop cancels the active install/build/Metro process group and removes this session's ADB reverse mapping. A failed stage logs its output and cleans up; it never leaves an Expo Go fallback running. Only one framework session owns the managed device at a time. Stop before switching between Flutter and Expo projects. Source snapshots cannot switch the framework of an active workspace.

After a service restart, start the device and Run again. If dependencies fail, fix the local project/lockfile or server package-manager setup and retry. If Metro is running but the app fails to connect, inspect app logs and verify the development client's SDK, ABI, scheme and native dependency compatibility. The shared Android viewer and ADB connection have their own reconnect behavior documented in [ANDROID.md](android.md).

## Verification status

Automated tests use controlled package-manager/Expo commands and a Metro command-socket fixture to exercise orchestration, source changes, native-rebuild detection, environment privacy, reload/menu delivery, cancellation and cleanup. Existing Flutter and native viewer tests remain part of verification. These tests do not constitute an actual Expo/Gradle build or a rendered development-client session on the Linux server; those are the next acceptance steps.
