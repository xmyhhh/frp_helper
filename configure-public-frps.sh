#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/frp"
CONFIG_DIR="/etc/frp"
SERVICE_NAME="frps"
ARCHIVE=""
SERVER_PORT=""
TOKEN=""
ALLOW_PORTS=()
NON_INTERACTIVE="0"

usage() {
  cat <<'EOF'
Usage:
  sudo bash configure-public-frps.sh

Optional non-interactive flags:
  sudo bash configure-public-frps.sh \
    --token <frp-token> \
    --server-port 7000 \
    --allow-port 18080 \
    --allow-port 10022 \
    [--archive ./frp_0.69.1_linux_amd64.tar.gz] \
    --yes

This script configures the public Linux server side: frps.
It uses a local frp_*.tar.gz archive from this directory. It does not download FRP.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

info() {
  echo "[frps] $*"
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local answer
  read -r -p "${prompt} [${default}]: " answer
  echo "${answer:-$default}"
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

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64 x86_64" ;;
    aarch64|arm64) echo "arm64 aarch64" ;;
    armv7l|armv7*) echo "arm armv7 armhf" ;;
    armv6l|armv6*) echo "arm armv6" ;;
    mips64) echo "mips64" ;;
    mips64el) echo "mips64le mips64el" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

find_archive() {
  local arch_candidates="$1"
  local matches=()
  shopt -s nullglob
  local arch
  for arch in ${arch_candidates}; do
    matches+=("${SCRIPT_DIR}"/frp_*_linux_"${arch}".tar.gz)
  done
  shopt -u nullglob
  if [[ "${#matches[@]}" -eq 0 ]]; then
    die "no matching FRP archive found for $(uname -m) in ${SCRIPT_DIR}. Expected one of: ${arch_candidates}. Pass --archive to choose manually."
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
      --server-port) SERVER_PORT="${2:-}"; shift 2 ;;
      --token) TOKEN="${2:-}"; shift 2 ;;
      --allow-port) ALLOW_PORTS+=("${2:-}"); shift 2 ;;
      --yes|-y) NON_INTERACTIVE="1"; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

run_wizard() {
  if [[ -z "${SERVER_PORT}" ]]; then
    SERVER_PORT="$(prompt_default "FRP control port on public server" "7000")"
  fi

  while ! validate_port "${SERVER_PORT}"; do
    SERVER_PORT="$(prompt_default "Invalid port. FRP control port" "7000")"
  done

  if [[ -z "${TOKEN}" ]]; then
    TOKEN="$(prompt_secret "FRP token, must match local frpc")"
  fi
  [[ -n "${TOKEN}" ]] || die "token is required"

  if [[ "${#ALLOW_PORTS[@]}" -eq 0 ]]; then
    echo
    echo "Enter public ports to expose. Defaults are:"
    echo "  18080 -> WSL viewer"
    echo "  10022 -> WSL SSH"
    local defaults
    defaults="$(prompt_default "Public ports, comma separated" "18080,10022")"
    IFS="," read -r -a ALLOW_PORTS <<<"${defaults}"
  fi

  local cleaned=()
  local port
  for port in "${ALLOW_PORTS[@]}"; do
    port="$(echo "${port}" | tr -d '[:space:]')"
    [[ -n "${port}" ]] || continue
    validate_port "${port}" || die "invalid public port: ${port}"
    cleaned+=("${port}")
  done
  ALLOW_PORTS=("${cleaned[@]}")
  [[ "${#ALLOW_PORTS[@]}" -gt 0 ]] || die "at least one public port is required"
}

install_frps() {
  local archive="$1"
  local tmp_dir
  tmp_dir="$(mktemp -d)"

  info "extracting ${archive}"
  tar -xzf "${archive}" -C "${tmp_dir}"
  local frps_path
  frps_path="$(find "${tmp_dir}" -type f -name frps | head -n 1)"
  [[ -n "${frps_path}" ]] || die "frps binary not found in archive"

  install -d "${INSTALL_DIR}"
  install -m 0755 "${frps_path}" "${INSTALL_DIR}/frps"
  rm -rf "${tmp_dir}"
}

write_config() {
  install -d "${CONFIG_DIR}"
  {
    printf 'bindPort = %s\n\n' "${SERVER_PORT}"
    printf 'auth.method = "token"\n'
    printf 'auth.token = "%s"\n' "${TOKEN//\"/\\\"}"
  } >"${CONFIG_DIR}/frps.toml"
  chmod 0600 "${CONFIG_DIR}/frps.toml"
}

write_service() {
  cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=FRP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/frps -c ${CONFIG_DIR}/frps.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

open_firewall() {
  local ports=("${SERVER_PORT}" "${ALLOW_PORTS[@]}")
  if command -v ufw >/dev/null 2>&1; then
    local port
    for port in "${ports[@]}"; do
      ufw allow "${port}/tcp" || true
    done
  fi

  echo
  echo "Make sure these TCP ports are open in your cloud security group/firewall:"
  local port
  for port in "${ports[@]}"; do
    echo "  ${port}/tcp"
  done
}

enable_service() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl is required on the public server"
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
  systemctl status "${SERVICE_NAME}" --no-pager || true
}

main() {
  parse_args "$@"
  [[ "${EUID}" -eq 0 ]] || die "please run with sudo"

  if [[ "${NON_INTERACTIVE}" != "1" ]]; then
    run_wizard
  fi

  [[ -n "${TOKEN}" ]] || die "--token is required"
  SERVER_PORT="${SERVER_PORT:-7000}"
  validate_port "${SERVER_PORT}" || die "--server-port must be 1-65535"
  if [[ "${#ALLOW_PORTS[@]}" -eq 0 ]]; then
    ALLOW_PORTS=("18080" "10022")
  fi

  local port
  for port in "${ALLOW_PORTS[@]}"; do
    validate_port "${port}" || die "invalid --allow-port value: ${port}"
  done

  if [[ -z "${ARCHIVE}" ]]; then
    ARCHIVE="$(find_archive "$(detect_arch)")"
  fi
  [[ -f "${ARCHIVE}" ]] || die "archive not found: ${ARCHIVE}"

  install_frps "${ARCHIVE}"
  write_config
  write_service
  enable_service
  open_firewall

  echo
  echo "Done. frps is running."
  echo "Control port: ${SERVER_PORT}"
  echo "Public service ports: ${ALLOW_PORTS[*]}"
}

main "$@"
