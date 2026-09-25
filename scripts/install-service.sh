#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DEFAULT_BINARY=$PROJECT_DIR/bin/okestra-service
UNIT_FILE=$PROJECT_DIR/deploy/systemd/okestra-service.service
if [ -x "$SCRIPT_DIR/okestra-service" ]; then
  DEFAULT_BINARY=$SCRIPT_DIR/okestra-service
fi
if [ -f "$SCRIPT_DIR/okestra-service.service" ]; then
  UNIT_FILE=$SCRIPT_DIR/okestra-service.service
fi
BINARY=$DEFAULT_BINARY
ENV_FILE=/etc/okestra/okestra.env
MODE=menu

usage() {
  printf '%s\n' 'Usage: sudo ./install-service.sh [--yes | --status | --show-connection] [path-to-okestra-service]'
  printf '%s\n' 'Guided menu opens automatically in a terminal. OKESTRA_INSTALL_ADDR sets the listener for unattended installation.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes) MODE=yes ;;
    --status) MODE=status ;;
    --show-connection) MODE=show-connection ;;
    --help|-h) usage; exit 0 ;;
    --*) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    *) BINARY=$1 ;;
  esac
  shift
done

if [ "$MODE" = menu ] && { [ ! -t 0 ] || [ ! -t 1 ]; }; then
  MODE=yes
fi

if [ "$(id -u)" -ne 0 ]; then
  printf 'Run the server installer as root: sudo %s\n' "$0" >&2
  exit 1
fi

current_value() {
  if [ -f "$ENV_FILE" ]; then
    sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1
  fi
}

validate_address() {
  case "$1" in
    *:*) ;;
    *) printf 'Address must include a port: %s\n' "$1" >&2; return 1 ;;
  esac
  host=${1%:*}
  port=${1##*:}
  case "$port" in
    ''|*[!0-9]*) printf 'Invalid TCP port: %s\n' "$port" >&2; return 1 ;;
  esac
  if [ -z "$host" ] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    printf 'Invalid listen address: %s\n' "$1" >&2
    return 1
  fi
}

new_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

show_connection() {
  if [ ! -f "$ENV_FILE" ]; then
    printf '%s\n' 'Okestra service is not configured yet.' >&2
    return 1
  fi
  address=$(current_value OKESTRA_SERVICE_ADDR)
  token=$(current_value OKESTRA_SERVICE_TOKEN)
  printf '\nService listener: %s\n' "$address"
  case "$address" in
    0.0.0.0:*|'[::]':*)
      printf 'Client URL: http://YOUR_SERVER_PRIVATE_ADDRESS:%s\n' "${address##*:}" ;;
    *) printf 'Client URL: http://%s\n' "$address" ;;
  esac
  printf 'Client token: %s\n' "$token"
  printf '%s\n' 'Keep the token private. The client wizard will ask for this URL and token.'
}

install_service() {
  if [ ! -x "$BINARY" ]; then
    printf 'Service binary not found or not executable: %s\n' "$BINARY" >&2
    exit 1
  fi
  if [ ! -f "$UNIT_FILE" ]; then
    printf 'Systemd unit not found: %s\n' "$UNIT_FILE" >&2
    exit 1
  fi
  for command in docker systemctl getent useradd usermod install; do
    if ! command -v "$command" >/dev/null 2>&1; then
      printf 'Required command is missing: %s\n' "$command" >&2
      exit 1
    fi
  done
  if ! getent group docker >/dev/null 2>&1; then
    printf '%s\n' 'The docker group does not exist; finish installing Docker Engine first.' >&2
    exit 1
  fi

  previous_address=$(current_value OKESTRA_SERVICE_ADDR)
  previous_token=$(current_value OKESTRA_SERVICE_TOKEN)
  listen_address=${OKESTRA_INSTALL_ADDR:-${previous_address:-0.0.0.0:8088}}
  if [ "$MODE" = menu ] && [ -z "${OKESTRA_INSTALL_ADDR:-}" ]; then
    printf '\nListen on a private address to limit who can reach the service.\n'
    printf 'Listen address [%s]: ' "$listen_address"
    IFS= read -r answer || answer=
    listen_address=${answer:-$listen_address}
  fi
  validate_address "$listen_address"
  if [ -n "$previous_token" ] && [ "${#previous_token}" -lt 32 ]; then
    printf '%s\n' 'Existing service token is too short; update /etc/okestra/okestra.env before reinstalling.' >&2
    exit 1
  fi
  token=${previous_token:-$(new_token)}

  if ! id okestra >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/okestra --shell /usr/sbin/nologin okestra
  fi
  usermod -aG docker okestra
  install -d -m 0750 -o okestra -g okestra /var/lib/okestra
  install -d -m 0750 -o root -g okestra /etc/okestra
  install -m 0755 "$BINARY" /usr/local/bin/okestra-service
  install -m 0644 "$UNIT_FILE" /etc/systemd/system/okestra-service.service

  temporary_env=$(mktemp /etc/okestra/okestra.env.XXXXXX)
  trap 'rm -f "$temporary_env"' EXIT HUP INT TERM
  if [ -f "$ENV_FILE" ]; then
    source_env=$ENV_FILE
  else
    source_env=/dev/null
  fi
  awk -v addr="$listen_address" -v token="$token" '
    /^OKESTRA_SERVICE_ADDR=/ { print "OKESTRA_SERVICE_ADDR=" addr; have_addr=1; next }
    /^OKESTRA_SERVICE_TOKEN=/ { print "OKESTRA_SERVICE_TOKEN=" token; have_token=1; next }
    /^OKESTRA_SERVICE_WORKDIR=/ { have_workdir=1 }
    { print }
    END {
      if (!have_addr) print "OKESTRA_SERVICE_ADDR=" addr
      if (!have_token) print "OKESTRA_SERVICE_TOKEN=" token
      if (!have_workdir) print "OKESTRA_SERVICE_WORKDIR=/var/lib/okestra"
    }
  ' "$source_env" >"$temporary_env"
  chown root:okestra "$temporary_env"
  chmod 0640 "$temporary_env"
  mv "$temporary_env" "$ENV_FILE"
  trap - EXIT HUP INT TERM

  systemctl daemon-reload
  systemctl enable okestra-service
  systemctl restart okestra-service
  if ! systemctl is-active --quiet okestra-service; then
    printf '%s\n' 'Service did not become active. Inspect: journalctl -u okestra-service -n 50' >&2
    exit 1
  fi
  printf '\n%s\n' 'Okestra service is installed and running.'
  show_connection
}

case "$MODE" in
  menu)
    printf '\nOkestra Linux server setup\n'
    printf '  1) Install or update the service\n'
    printf '  2) Show service status\n'
    printf '  3) Show client connection details\n'
    printf '  4) Exit\n'
    printf 'Choose [1]: '
    IFS= read -r choice || choice=
    case "${choice:-1}" in
      1) install_service ;;
      2) systemctl status okestra-service --no-pager ;;
      3) show_connection ;;
      4) exit 0 ;;
      *) printf 'Invalid choice: %s\n' "$choice" >&2; exit 1 ;;
    esac
    ;;
  yes) install_service ;;
  status) systemctl status okestra-service --no-pager ;;
  show-connection) show_connection ;;
esac
