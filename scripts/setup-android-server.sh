#!/bin/sh
# Configure Android emulator tools (legacy development tools are opt-in) for the existing Okestra service.
set -eu
usage() { printf '%s\n' 'Device-only setup: sudo ./setup-android-server.sh --install [AVD_NAME]' 'Existing Android SDK: sudo ./setup-android-server.sh --sdk /var/lib/okestra/android-sdk [AVD_NAME]' 'Installs the Android emulator, platform tools and API 35 image, reviews SDK licenses, configures KVM and enables Android in Okestra.' 'Archived development setup (explicit opt-in only): OKESTRA_ANDROID_DEVELOPMENT_ENABLED=1 ./setup-android-server.sh /opt/flutter /var/lib/okestra/android-sdk [AVD_NAME]'; }
if [ "${1:-}" = --help ]; then usage; exit 0; fi
if [ "${1:-}" = --expo ]; then
 [ "${OKESTRA_ANDROID_DEVELOPMENT_ENABLED:-0}" = 1 ] || { printf '%s\n' 'Expo server builds are archived. Use local development tools with the remote ADB device.' >&2; exit 1; }
 [ "$(id -u)" -eq 0 ] && [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || { printf '%s\n' 'Run as root on the x86_64 Android server.' >&2; exit 1; }
 id okestra >/dev/null
 SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
 install -m 0644 "$SCRIPT_DIR/android-tools.py" /var/lib/okestra/android-tools-installer.py
 runuser -u okestra -- env HOME=/var/lib/okestra python3 /var/lib/okestra/android-tools-installer.py --node-only
 printf '%s\n' 'Node and npm are ready for Expo development builds. Install this release of okestra-service before using Expo commands.'
 exit 0
fi
if [ "${1:-}" = --install ]; then
 [ "$(id -u)" -eq 0 ] && [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || { printf '%s\n' 'Run as root on an x86_64 Linux server.' >&2; exit 1; }
 [ -f /etc/os-release ] || exit 1
 . /etc/os-release
 case "${ID:-}" in ubuntu|debian) ;; *) printf '%s\n' 'Automatic dependencies currently support Ubuntu and Debian; use explicit SDK paths on other distributions.' >&2; exit 1;; esac
 SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
 [ -c /dev/kvm ] || { printf '%s\n' 'Hardware virtualization is required. Enable KVM/nested virtualization before installation.' >&2; exit 1; }
 if [ ! -f /etc/okestra/okestra.env ] && [ -z "${OKESTRA_INSTALL_ADDR:-}" ]; then
  printf 'Private server IP and port (for example 192.168.1.10:8088): '
  IFS= read -r OKESTRA_INSTALL_ADDR
  [ -n "$OKESTRA_INSTALL_ADDR" ] || { printf '%s\n' 'A reachable private address is required.' >&2; exit 1; }
  export OKESTRA_INSTALL_ADDR
 fi
 apt-get update
 apt-get install -y curl git unzip xz-utils python3 openjdk-17-jdk qemu-system-x86 libglu1-mesa libpulse0 libnss3 libx11-6 libxcb-cursor0 libxkbcommon0 libxcomposite1 libxi6 libxtst6
 if ! command -v docker >/dev/null 2>&1; then apt-get install -y docker.io; systemctl enable --now docker; fi
 if [ -x "$SCRIPT_DIR/okestra-service" ]; then "$SCRIPT_DIR/install-service.sh" --yes "$SCRIPT_DIR/okestra-service"
 elif [ -x "$SCRIPT_DIR/../bin/okestra-service-linux-amd64" ]; then "$SCRIPT_DIR/install-service.sh" --yes "$SCRIPT_DIR/../bin/okestra-service-linux-amd64"
 elif [ -x "$SCRIPT_DIR/../bin/okestra-service" ]; then "$SCRIPT_DIR/install-service.sh" --yes "$SCRIPT_DIR/../bin/okestra-service"
 elif [ ! -f /etc/okestra/okestra.env ]; then printf '%s\n' 'Build or extract the Linux service package first.' >&2; exit 1; fi
 install -d -m 0750 -o okestra -g okestra /var/lib/okestra
 install -m 0644 "$SCRIPT_DIR/android-tools.py" /var/lib/okestra/android-tools-installer.py
 runuser -u okestra -- env HOME=/var/lib/okestra python3 /var/lib/okestra/android-tools-installer.py --sdk-only
 exec "$0" --sdk /var/lib/okestra/android-sdk "${2:-okestra-pixel}"
fi
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then usage >&2; exit 1; fi
if [ "$(id -u)" -ne 0 ] || [ "$(uname -s)" != Linux ]; then printf '%s\n' 'Run as root on the Linux server.' >&2; exit 1; fi
if [ "$(uname -m)" != x86_64 ]; then printf '%s\n' 'The initial Android emulator workflow requires an x86_64 Linux server.' >&2; exit 1; fi
development=0
flutter=
if [ "$1" = --sdk ]; then
 sdk=$(readlink -f "$2")
 avd=${3:-okestra-pixel}
else
 [ "${OKESTRA_ANDROID_DEVELOPMENT_ENABLED:-0}" = 1 ] || { printf '%s\n' 'Project build tool setup is archived. Use --sdk PATH or --install for emulator-only setup.' >&2; exit 1; }
 development=1
 flutter=$(readlink -f "$1")
 sdk=$(readlink -f "$2")
 avd=${3:-okestra-pixel}
fi
for value in "$sdk" "$avd" ${flutter:+"$flutter"}; do
 case "$value" in *[!A-Za-z0-9_./-]*|'') printf '%s\n' 'Use paths and AVD names without spaces or shell characters.' >&2; exit 1;; esac
done
case "$avd" in -*|*/*|*..*) printf '%s\n' 'Invalid AVD name.' >&2; exit 1;; esac
for path in "$sdk" ${flutter:+"$flutter"}; do
 case "$path" in /opt/*|/var/lib/okestra/*) ;; *) printf '%s\n' 'Use dedicated SDK directories under /opt or /var/lib/okestra.' >&2; exit 1;; esac
done
id okestra >/dev/null
command -v java >/dev/null
command -v runuser >/dev/null
[ "$development" = 0 ] || [ -x "$flutter/bin/flutter" ] || { printf '%s\n' 'Flutter executable not found.' >&2; exit 1; }
[ -x "$sdk/cmdline-tools/latest/bin/sdkmanager" ] || { printf '%s\n' 'Expected Android tools at SDK/cmdline-tools/latest/bin/sdkmanager.' >&2; exit 1; }
[ -f /etc/okestra/okestra.env ] || { printf '%s\n' 'Install the Okestra service first.' >&2; exit 1; }
[ -c /dev/kvm ] || { printf '%s\n' 'KVM unavailable; enable hardware virtualization and install qemu-system-x86 first.' >&2; exit 1; }
getent group kvm >/dev/null
usermod -aG kvm okestra
install -d -m 0750 -o okestra -g okestra /var/lib/okestra/.android
as_service() { (cd /var/lib/okestra && runuser -u okestra -- env HOME=/var/lib/okestra ANDROID_HOME="$sdk" ANDROID_USER_HOME=/var/lib/okestra/.android "$@"); }
as_service test -w "$sdk" || { printf '%s\n' 'The dedicated Android SDK directory must be writable by okestra.' >&2; exit 1; }
[ "$development" = 0 ] || as_service test -w "$flutter" || { printf '%s\n' 'Flutter must be writable by okestra to populate its tool cache.' >&2; exit 1; }
as_service "$sdk/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$sdk" --licenses
if [ "$development" = 1 ]; then as_service "$sdk/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$sdk" 'platforms;android-35' 'build-tools;35.0.0'; fi
as_service "$sdk/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$sdk" 'platform-tools' 'emulator' 'system-images;android-35;google_apis;x86_64'
if ! as_service "$sdk/emulator/emulator" -list-avds | awk -v name="$avd" '$0 == name { found=1 } END { exit !found }'; then
 printf 'no\n' | as_service "$sdk/cmdline-tools/latest/bin/avdmanager" create avd --name "$avd" --package 'system-images;android-35;google_apis;x86_64' --device pixel_7
fi
as_service "$sdk/emulator/emulator" -accel-check
if [ "$development" = 1 ]; then
 as_service "$flutter/bin/flutter" config --android-sdk "$sdk"
 as_service "$flutter/bin/flutter" doctor -v
fi
# Preserve Docker/token settings; restore service configuration on any activation failure.
backup=$(mktemp -d /etc/okestra/android-rollback.XXXXXX)
cp -p /etc/okestra/okestra.env "$backup/environment"
dropin=/etc/systemd/system/okestra-service.service.d/android.conf
if [ -f "$dropin" ]; then cp -p "$dropin" "$backup/android.conf"; fi
success=no
tmp=
rollback() {
 result=$?
 trap - EXIT HUP INT TERM
 if [ "$success" != yes ]; then
  cp -p "$backup/environment" /etc/okestra/okestra.env
  if [ -f "$backup/android.conf" ]; then cp -p "$backup/android.conf" "$dropin"; else rm -f "$dropin"; fi
  systemctl daemon-reload || true
  systemctl restart okestra-service || true
  printf '%s\n' 'Android activation failed; previous service configuration restored. Inspect journalctl -u okestra-service.' >&2
 fi
 if [ -n "$tmp" ]; then rm -f "$tmp"; fi
 rm -rf "$backup"
 exit "$result"
}
trap rollback EXIT
trap 'exit 1' HUP INT TERM
tmp=$(mktemp /etc/okestra/android-env.XXXXXX)
awk '!/^(OKESTRA_ANDROID_ENABLED|OKESTRA_ANDROID_DEVELOPMENT_ENABLED|OKESTRA_FLUTTER_BIN|ANDROID_HOME|ANDROID_USER_HOME|HOME)=/' /etc/okestra/okestra.env > "$tmp"
printf 'OKESTRA_ANDROID_ENABLED=1\nOKESTRA_ANDROID_DEVELOPMENT_ENABLED=%s\nANDROID_HOME=%s\nANDROID_USER_HOME=/var/lib/okestra/.android\nHOME=/var/lib/okestra\n' "$development" "$sdk" >> "$tmp"
if [ "$development" = 1 ]; then printf 'OKESTRA_FLUTTER_BIN=%s/bin/flutter\n' "$flutter" >> "$tmp"; fi
chown root:okestra "$tmp"
chmod 0640 "$tmp"
mv "$tmp" /etc/okestra/okestra.env
install -d -m 0755 /etc/systemd/system/okestra-service.service.d
printf '[Service]\nReadWritePaths=%s\n' "$sdk" > "$dropin"
if [ "$development" = 1 ]; then printf 'ReadWritePaths=%s\n' "$flutter" >> "$dropin"; fi
chmod 0644 "$dropin"
systemctl daemon-reload
systemctl restart okestra-service
systemctl is-active --quiet okestra-service
success=yes
printf 'Android enabled. On your Mac run: okestra android doctor\nAVD: %s\n' "$avd"
