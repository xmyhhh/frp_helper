#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-/etc/frp/frpc.toml}"
SERVICE_NAME="frpc"

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

check_tcp() {
  local host="$1"
  local port="$2"
  if timeout 2 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" 2>/dev/null; then
    echo "ok: ${host}:${port} reachable"
  else
    echo "fail: ${host}:${port} not reachable"
  fi
}

section "frpc service"
if command -v systemctl >/dev/null 2>&1; then
  systemctl status "${SERVICE_NAME}" --no-pager || true
  echo
  echo "enabled: $(systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null || true)"
else
  echo "systemctl not found"
fi

section "frpc config"
redact_config

section "server connectivity"
if [[ -f "${CONFIG_FILE}" ]]; then
  server_addr="$(config_value serverAddr)"
  server_port="$(config_value serverPort)"
  if [[ -n "${server_addr}" && -n "${server_port}" ]]; then
    check_tcp "${server_addr}" "${server_port}"
  else
    echo "serverAddr/serverPort not found in ${CONFIG_FILE}"
  fi
fi

section "local mapped services"
if [[ -f "${CONFIG_FILE}" ]]; then
  awk '
    function trim(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      return v
    }
    /^\[\[proxies\]\]/ {
      if (name != "") print name, localIP, localPort, remotePort
      name=""; localIP="127.0.0.1"; localPort=""; remotePort=""
      next
    }
    /^[[:space:]]*name[[:space:]]*=/ { split($0,a,"="); name=trim(a[2]) }
    /^[[:space:]]*localIP[[:space:]]*=/ { split($0,a,"="); localIP=trim(a[2]) }
    /^[[:space:]]*localPort[[:space:]]*=/ { split($0,a,"="); localPort=trim(a[2]) }
    /^[[:space:]]*remotePort[[:space:]]*=/ { split($0,a,"="); remotePort=trim(a[2]) }
    END {
      if (name != "") print name, localIP, localPort, remotePort
    }
  ' "${CONFIG_FILE}" | while read -r name local_ip local_port remote_port; do
    echo "${name}: ${local_ip}:${local_port} -> public:${remote_port}"
    check_tcp "${local_ip}" "${local_port}"
  done
fi

section "local listening ports"
if command -v ss >/dev/null 2>&1; then
  ss -lntp || true
elif command -v netstat >/dev/null 2>&1; then
  netstat -lntp || true
else
  echo "ss/netstat not found"
fi

section "ssh quick check"
if command -v systemctl >/dev/null 2>&1; then
  systemctl status ssh --no-pager || systemctl status sshd --no-pager || true
fi
if command -v service >/dev/null 2>&1; then
  service ssh status || true
fi

section "recent frpc logs"
if command -v journalctl >/dev/null 2>&1; then
  journalctl -u "${SERVICE_NAME}" -n 80 --no-pager || true
else
  echo "journalctl not found"
fi

