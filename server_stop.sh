#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="frps"
DISABLE="0"

usage() {
  cat <<'EOF'
Usage:
  sudo bash server_stop.sh [--disable]

Stops the public Linux server frps service.

Options:
  --disable    Also disable frps auto-start on boot.
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
  echo "error: systemctl is required on the public server" >&2
  exit 1
fi

systemctl stop "${SERVICE_NAME}" || true

if [[ "${DISABLE}" == "1" ]]; then
  systemctl disable "${SERVICE_NAME}" || true
fi

systemctl status "${SERVICE_NAME}" --no-pager || true

echo
if [[ "${DISABLE}" == "1" ]]; then
  echo "frps stopped and disabled."
else
  echo "frps stopped. Auto-start is unchanged."
fi
