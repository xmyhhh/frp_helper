#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-/etc/frp/frps.toml}"
SERVICE_NAME="frps"

usage() {
  cat <<'EOF'
Usage:
  sudo bash server_status.sh [config-file] [public-port...]

Examples:
  sudo bash server_status.sh
  sudo bash server_status.sh /etc/frp/frps.toml 18765 10022

Run this on the public Linux server.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

section() {
  echo
  echo "== $* =="
}

redact_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "config not found: ${CONFIG_FILE}"
    return
  fi
  sed -E 's/(auth\.token[[:space:]]*=[[:space:]]*").*(")/\1***\2/' "${CONFIG_FILE}"
}

config_value() {
  local key="$1"
  awk -F '=' -v key="${key}" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "${CONFIG_FILE}" 2>/dev/null || true
}

section "frps service"
if command -v systemctl >/dev/null 2>&1; then
  systemctl status "${SERVICE_NAME}" --no-pager || true
  echo
  echo "enabled: $(systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null || true)"
else
  echo "systemctl not found"
fi

section "frps config"
redact_config

section "listening ports"
if command -v ss >/dev/null 2>&1; then
  ss -lntp || true
elif command -v netstat >/dev/null 2>&1; then
  netstat -lntp || true
else
  echo "ss/netstat not found"
fi

section "expected ports"
bind_port="$(config_value bindPort)"
if [[ -n "${bind_port}" ]]; then
  echo "frps control port from config: ${bind_port}"
fi
if [[ "$#" -gt 1 ]]; then
  shift
  echo "public service ports supplied on command line:"
  for port in "$@"; do
    echo "  ${port}"
    if command -v ss >/dev/null 2>&1; then
      if ss -lnt "( sport = :${port} )" | grep -q ":${port}"; then
        echo "    listen: yes"
      else
        echo "    listen: no"
      fi
    fi
  done
else
  echo "Tip: pass public service ports to check, for example:"
  echo "  sudo bash server_status.sh /etc/frp/frps.toml 18765 10022"
fi

section "firewall"
if command -v ufw >/dev/null 2>&1; then
  ufw status verbose || true
else
  echo "ufw not found. Also check your cloud security group manually."
fi

section "recent frps logs"
if command -v journalctl >/dev/null 2>&1; then
  journalctl -u "${SERVICE_NAME}" -n 120 --no-pager || true
else
  echo "journalctl not found"
fi

section "ssh tunnel hints"
cat <<'EOF'
If SSH via FRP cannot connect:
  1. On the local/WSL side, run: sudo bash client_status.sh
  2. Confirm local 127.0.0.1:22 is reachable in WSL.
  3. Confirm frpc logs show the ssh proxy started successfully.
  4. Confirm the public remotePort is listening on this server.
  5. Confirm the cloud security group allows that remotePort, for example 10022/tcp.
EOF
