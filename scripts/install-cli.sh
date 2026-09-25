#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DEFAULT_BINARY=$PROJECT_DIR/bin/okestra
if [ -x "$SCRIPT_DIR/okestra" ]; then
  DEFAULT_BINARY=$SCRIPT_DIR/okestra
fi
BINARY=$DEFAULT_BINARY
DESTINATION=${OKESTRA_INSTALL_BIN:-/usr/local/bin/okestra}
MODE=menu

usage() {
  printf '%s\n' 'Usage: install-cli.sh [--yes | --install-only | --connect-only] [path-to-okestra]'
  printf '%s\n' 'Guided menu opens automatically in a terminal.'
  printf '%s\n' 'For unattended pairing, set OKESTRA_SETUP_NAME, OKESTRA_SETUP_URL and OKESTRA_TOKEN.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes) MODE=yes ;;
    --install-only) MODE=install-only ;;
    --connect-only) MODE=connect-only ;;
    --help|-h) usage; exit 0 ;;
    --*) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    *) BINARY=$1 ;;
  esac
  shift
done

if [ "$MODE" = menu ] && { [ ! -t 0 ] || [ ! -t 1 ]; }; then
  MODE=yes
fi

install_cli() {
  if [ ! -x "$BINARY" ]; then
    printf 'CLI binary not found or not executable: %s\n' "$BINARY" >&2
    exit 1
  fi
  if [ ! -d "$(dirname "$DESTINATION")" ]; then
    printf 'Install directory does not exist: %s\n' "$(dirname "$DESTINATION")" >&2
    exit 1
  fi
  if [ -w "$(dirname "$DESTINATION")" ]; then
    install -m 0755 "$BINARY" "$DESTINATION"
  else
    sudo install -m 0755 "$BINARY" "$DESTINATION"
  fi
  printf '\nInstalled %s\n' "$DESTINATION"
  "$DESTINATION" version
}

ask_value() {
  prompt=$1
  fallback=$2
  printf '%s [%s]: ' "$prompt" "$fallback" >&2
  IFS= read -r answer || answer=
  printf '%s\n' "${answer:-$fallback}"
}

read_secret() {
  if [ -n "${OKESTRA_TOKEN:-}" ]; then
    printf '%s\n' "$OKESTRA_TOKEN"
    return
  fi
  if [ ! -t 0 ]; then
    printf '%s\n' 'OKESTRA_TOKEN is required for unattended pairing.' >&2
    return 1
  fi
  printf 'Paste the server token (input hidden): ' >&2
  stty -echo
  trap 'stty echo' EXIT HUP INT TERM
  IFS= read -r secret || secret=
  stty echo
  trap - EXIT HUP INT TERM
  printf '\n' >&2
  printf '%s\n' "$secret"
}

connect_server() {
  if [ ! -x "$DESTINATION" ]; then
    printf 'CLI is not installed at %s. Choose installation first.\n' "$DESTINATION" >&2
    exit 1
  fi
  if [ "$MODE" = menu ]; then
    name=$(ask_value 'Server profile name' "${OKESTRA_SETUP_NAME:-devbox}")
    address=$(ask_value 'Private server URL (for example http://100.64.0.10:8088)' "${OKESTRA_SETUP_URL:-http://SERVER_PRIVATE_ADDRESS:8088}")
  else
    name=${OKESTRA_SETUP_NAME:-devbox}
    address=${OKESTRA_SETUP_URL:-}
  fi
  if [ -z "$address" ] || [ "$address" = 'http://SERVER_PRIVATE_ADDRESS:8088' ]; then
    printf '%s\n' 'Enter a real private server URL before pairing.' >&2
    exit 1
  fi
  token=$(read_secret)
  if [ -z "$token" ]; then
    printf '%s\n' 'Server token cannot be empty.' >&2
    exit 1
  fi
  OKESTRA_TOKEN=$token "$DESTINATION" server add --name "$name" --url "$address"
  unset token
  if [ "$MODE" = menu ]; then
    printf 'Run connection check now? [Y/n]: ' >&2
    IFS= read -r choice || choice=
    case "$choice" in
      n|N) return ;;
    esac
  fi
  if ! "$DESTINATION" doctor; then
    printf '\nCLI and profile are installed. Check the server address and network, then run: okestra doctor\n' >&2
  fi
}

case "$MODE" in
  menu)
    printf '\nOkestra developer setup\n'
    printf '  1) Install CLI and connect to a server\n'
    printf '  2) Install or update CLI only\n'
    printf '  3) Connect the already installed CLI\n'
    printf '  4) Exit\n'
    printf 'Choose [1]: '
    IFS= read -r choice || choice=
    case "${choice:-1}" in
      1) install_cli; connect_server ;;
      2) install_cli ;;
      3) connect_server ;;
      4) exit 0 ;;
      *) printf 'Invalid choice: %s\n' "$choice" >&2; exit 1 ;;
    esac
    ;;
  install-only) install_cli ;;
  connect-only) connect_server ;;
  yes)
    install_cli
    if [ -n "${OKESTRA_SETUP_URL:-}" ]; then
      connect_server
    else
      printf 'To connect later, rerun %s --connect-only with OKESTRA_SETUP_URL and OKESTRA_TOKEN.\n' "$0"
    fi
    ;;
esac
