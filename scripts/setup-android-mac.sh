#!/bin/sh
set -eu
if [ "${1:-}" = --help ]; then printf '%s\n' 'Usage: setup-android-mac.sh' 'Installs verified official Android platform tools for the current Mac user. No Homebrew, Flutter, or Android Studio required.'; exit 0; fi
[ "$(uname -s)" = Darwin ] || { printf '%s\n' 'Run this on your Mac.' >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { printf '%s\n' 'Run as your normal Mac user, without sudo.' >&2; exit 1; }
root="$HOME/Library/Application Support/Okestra"
if [ -x "$root/platform-tools/adb" ]; then "$root/platform-tools/adb" version; exit 0; fi
printf '%s\n' 'Android platform tools are supplied by Google under the Android SDK license.' 'Review: https://developer.android.com/studio/terms' 'Download and install for this user? [y/N]'
IFS= read -r answer
case "$answer" in y|Y|yes|YES) ;; *) printf '%s\n' 'Android tools not installed.'; exit 1;; esac
mkdir -p "$root"
work=$(mktemp -d "$root/.android-install.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
curl -fLsS --retry 3 --connect-timeout 15 --max-time 300 --proto '=https' --proto-redir '=https' https://dl.google.com/android/repository/repository2-1.xml -o "$work/repository.xml"
node="//*[local-name()='remotePackage' and @path='platform-tools']/*[local-name()='archives']/*[local-name()='archive'][*[local-name()='host-os']='macosx']/*[local-name()='complete']"
xml() { xmllint --nonet --xpath "string($node/$1)" "$work/repository.xml"; }
archive=$(xml "*[local-name()='url']")
expected=$(xml "*[local-name()='checksum']")
algorithm=$(xml "*[local-name()='checksum']/@type")
case "$archive" in platform-tools*darwin.zip) ;; *) printf '%s\n' 'Invalid Google platform-tools manifest.' >&2; exit 1;; esac
case "$archive" in *'/'*|*'..'*) exit 1;; esac
case "$algorithm" in sha1|'') bits=1;; sha256) bits=256;; *) printf '%s\n' 'Unsupported archive checksum algorithm.' >&2; exit 1;; esac
[ -n "$expected" ] || { printf '%s\n' 'Official archive checksum missing.' >&2; exit 1; }
curl -fLsS --retry 3 --connect-timeout 15 --max-time 600 --proto '=https' --proto-redir '=https' "https://dl.google.com/android/repository/$archive" -o "$work/tools.zip"
actual=$(shasum -a "$bits" "$work/tools.zip" | awk '{print $1}')
[ "$actual" = "$expected" ] || { printf '%s\n' 'Android archive checksum mismatch.' >&2; exit 1; }
unzip -q "$work/tools.zip" -d "$work/unpacked"
[ -x "$work/unpacked/platform-tools/adb" ] || { printf '%s\n' 'The platform-tools archive is incomplete.' >&2; exit 1; }
"$work/unpacked/platform-tools/adb" version
mv "$work/unpacked/platform-tools" "$root/platform-tools"
printf 'Android tools installed in %s/platform-tools\n' "$root"
