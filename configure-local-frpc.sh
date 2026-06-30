#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/frp"
CONFIG_DIR="/etc/frp"
SERVICE_NAME="frpc"
ARCHIVE=""
SERVER_ADDR=""
SERVER_PORT=""
TOKEN=""
MAPS=()
NON_INTERACTIVE="0"

usage() {
  cat <<'EOF'
Usage:
  sudo bash configure-local-frpc.sh

Optional non-interactive flags:
  sudo bash configure-local-frpc.sh \
    --server-addr <public-server-ip-or-host> \
    --token <frp-token> \
    --server-port 7000 \
    --map viewer:8765:18080 \
    --map ssh:22:10022 \
    [--archive ./frp_0.69.1_linux_amd64.tar.gz] \
    --yes

Map format:
  name:local_port:remote_port[:local_ip]

Examples:
  viewer:8765:18080
  ssh:22:10022
  api:3000:13000
  postgres:5432:15432:127.0.0.1

This script configures the local Linux/WSL side: frpc.
It uses a local frp_*.tar.gz archive from this directory. It does not download FRP.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

info() {
  echo "[frpc] $*"
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local answer
  read -r -p "${prompt} [${default}]: " answer
  echo "${answer:-$default}"
}

prompt_required() {
  local prompt="$1"
  local answer
  while true; do
    read -r -p "${prompt}: " answer
    if [[ -n "${answer}" ]]; then
      echo "${answer}"
      return
    fi
  done
}

prompt_secret() {
  local prompt="$1"
  local answer
  read -r -s -p "${prompt}: " answer
  echo
  echo "${answer}"
}

validate_port() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  (( value >= 1 && value <= 65535 ))
}

validate_map() {
  local raw="$1"
  local name local_port remote_port local_ip extra
  IFS=":" read -r name local_port remote_port local_ip extra <<<"${raw}"
  [[ -n "${name:-}" && -n "${local_port:-}" && -n "${remote_port:-}" ]] || return 1
  [[ -z "${extra:-}" ]] || return 1
  [[ "${name}" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  validate_port "${local_port}" || return 1
  validate_port "${remote_port}" || return 1
  return 0
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "arm" ;;
    mips64) echo "mips64" ;;
    mips64el) echo "mips64le" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

find_archive() {
  local arch="$1"
  local matches=()
  shopt -s nullglob
  matches=("${SCRIPT_DIR}"/frp_*_linux_"${arch}".tar.gz)
  shopt -u nullglob
  if [[ "${#matches[@]}" -eq 0 ]]; then
    die "no matching FRP archive found for linux_${arch} in ${SCRIPT_DIR}. Put frp_*_linux_${arch}.tar.gz here or pass --archive."
  fi
  if [[ "${#matches[@]}" -gt 1 ]]; then
    die "multiple matching archives found. Pass --archive explicitly."
  fi
  echo "${matches[0]}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --archive) ARCHIVE="${2:-}"; shift 2 ;;
      --server-addr) SERVER_ADDR="${2:-}"; shift 2 ;;
      --server-port) SERVER_PORT="${2:-}"; shift 2 ;;
      --token) TOKEN="${2:-}"; shift 2 ;;
      --map) MAPS+=("${2:-}"); shift 2 ;;
      --yes|-y) NON_INTERACTIVE="1"; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

add_map_wizard() {
  local default_name="$1"
  local default_local="$2"
  local default_remote="$3"
  local use_it
  use_it="$(prompt_default "Add ${default_name} mapping ${default_local}->${default_remote}? y/n" "y")"
  case "${use_it}" in
    y|Y|yes|YES)
      MAPS+=("${default_name}:${default_local}:${default_remote}:127.0.0.1")
      ;;
  esac
}

run_wizard() {
  [[ -n "${SERVER_ADDR}" ]] || SERVER_ADDR="$(prompt_required "Public server IP or hostname")"
  [[ -n "${SERVER_PORT}" ]] || SERVER_PORT="$(prompt_default "FRP control port on public server" "7000")"
  while ! validate_port "${SERVER_PORT}"; do
    SERVER_PORT="$(prompt_default "Invalid port. FRP control port" "7000")"
  done

  if [[ -z "${TOKEN}" ]]; then
    TOKEN="$(prompt_secret "FRP token, must match public frps")"
  fi
  [[ -n "${TOKEN}" ]] || die "token is required"

  if [[ "${#MAPS[@]}" -eq 0 ]]; then
    add_map_wizard "viewer" "8765" "18080"
    add_map_wizard "ssh" "22" "10022"

    while true; do
      local more
      more="$(prompt_default "Add another port mapping? y/n" "n")"
      case "${more}" in
        y|Y|yes|YES)
          local name local_port remote_port local_ip
          name="$(prompt_required "Mapping name, letters/numbers/_/- only")"
          local_port="$(prompt_required "Local service port in WSL")"
          remote_port="$(prompt_required "Public remote port on server")"
          local_ip="$(prompt_default "Local IP" "127.0.0.1")"
          MAPS+=("${name}:${local_port}:${remote_port}:${local_ip}")
          ;;
        *)
          break
          ;;
      esac
    done
  fi
}

install_frpc() {
  local archive="$1"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT

  info "extracting ${archive}"
  tar -xzf "${archive}" -C "${tmp_dir}"
  local frpc_path
  frpc_path="$(find "${tmp_dir}" -type f -name frpc | head -n 1)"
  [[ -n "${frpc_path}" ]] || die "frpc binary not found in archive"

  install -d "${INSTALL_DIR}"
  install -m 0755 "${frpc_path}" "${INSTALL_DIR}/frpc"
}

write_config() {
  install -d "${CONFIG_DIR}"
  {
    printf 'serverAddr = "%s"\n' "${SERVER_ADDR}"
    printf 'serverPort = %s\n\n' "${SERVER_PORT}"
    printf 'auth.method = "token"\n'
    printf 'auth.token = "%s"\n\n' "${TOKEN//\"/\\\"}"

    local raw name local_port remote_port local_ip
    for raw in "${MAPS[@]}"; do
      IFS=":" read -r name local_port remote_port local_ip <<<"${raw}"
      local_ip="${local_ip:-127.0.0.1}"
      cat <<EOF
[[proxies]]
name = "${name}"
type = "tcp"
localIP = "${local_ip}"
localPort = ${local_port}
remotePort = ${remote_port}

EOF
    done
  } >"${CONFIG_DIR}/frpc.toml"
  chmod 0600 "${CONFIG_DIR}/frpc.toml"
}

write_service() {
  cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=FRP Client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/frpc -c ${CONFIG_DIR}/frpc.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

enable_service() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-units >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}"
    systemctl status "${SERVICE_NAME}" --no-pager || true
  else
    echo
    echo "systemd is not available in this WSL distro."
    echo "Start frpc manually with:"
    echo "  sudo ${INSTALL_DIR}/frpc -c ${CONFIG_DIR}/frpc.toml"
  fi
}

main() {
  parse_args "$@"
  [[ "${EUID}" -eq 0 ]] || die "please run with sudo"

  if [[ "${NON_INTERACTIVE}" != "1" ]]; then
    run_wizard
  fi

  [[ -n "${SERVER_ADDR}" ]] || die "--server-addr is required"
  [[ -n "${TOKEN}" ]] || die "--token is required"
  SERVER_PORT="${SERVER_PORT:-7000}"
  validate_port "${SERVER_PORT}" || die "--server-port must be 1-65535"
  if [[ "${#MAPS[@]}" -eq 0 ]]; then
    MAPS=("viewer:8765:18080:127.0.0.1" "ssh:22:10022:127.0.0.1")
  fi

  local raw
  for raw in "${MAPS[@]}"; do
    validate_map "${raw}" || die "invalid --map value: ${raw}"
  done

  if [[ -z "${ARCHIVE}" ]]; then
    ARCHIVE="$(find_archive "$(detect_arch)")"
  fi
  [[ -f "${ARCHIVE}" ]] || die "archive not found: ${ARCHIVE}"

  install_frpc "${ARCHIVE}"
  write_config
  write_service
  enable_service

  echo
  echo "Done. frpc is configured."
  echo "Public addresses:"
  for raw in "${MAPS[@]}"; do
    local name local_port remote_port local_ip
    IFS=":" read -r name local_port remote_port local_ip <<<"${raw}"
    echo "  ${name}: ${SERVER_ADDR}:${remote_port} -> ${local_ip:-127.0.0.1}:${local_port}"
  done
}

main "$@"
