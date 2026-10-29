#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "$(uname -s)" in
 Darwin)
  [ "$(id -u)" -ne 0 ] || { printf '%s\n' 'Run on your Mac without sudo; the installer asks for privileges only if needed.' >&2; exit 1; }
  exec "$ROOT/install-cli.sh" --android "$@";;
 Linux)
  [ -x "$ROOT/setup-android-server.sh" ] || { printf '%s\n' 'Use the Linux service archive for server installation.' >&2; exit 1; }
  [ "$(id -u)" -eq 0 ] || { printf '%s\n' 'Run: sudo ./install-android.sh'; exit 1; }
  "$ROOT/setup-android-server.sh" --install "$@";;
 *) printf '%s\n' 'Android setup supports macOS clients and x86_64 Ubuntu servers.' >&2; exit 1;;
esac
