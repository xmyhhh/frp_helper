#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="frpc"
DISABLE="0"

usage() {
  cat <<'EOF'
Usage:
  sudo bash client_stop.sh [--disable]

Stops the local Linux/WSL frpc service.

Options:
  --disable    Also disable frpc auto-start on boot.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disable) DISABLE="1"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "error: please run with sudo" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl not found. If frpc was started manually, stop that process manually."
  exit 0
fi

systemctl stop "${SERVICE_NAME}" || true

if [[ "${DISABLE}" == "1" ]]; then
  systemctl disable "${SERVICE_NAME}" || true
fi

systemctl status "${SERVICE_NAME}" --no-pager || true

echo
if [[ "${DISABLE}" == "1" ]]; then
  echo "frpc stopped and disabled."
else
  echo "frpc stopped. Auto-start is unchanged."
fi
