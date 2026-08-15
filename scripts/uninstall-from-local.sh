#!/usr/bin/env bash
# Disable idle-low-load shutdown timer and remove installed units + binaries.
# Usage: uninstall-from-local.sh [--purge-config]
set -euo pipefail

BIN="${HOME}/.local/bin"
CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/graceful-shutdown"
SYSTEMD_USER="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
LIB_DIR="${BIN}/graceful-shutdown-lib"
PURGE_CONFIG=0

for arg in "$@"; do
  case "${arg}" in
    --purge-config) PURGE_CONFIG=1 ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--purge-config]"
      echo "  Removes binaries, libs, and user units. Keeps config unless --purge-config."
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      exit 2
      ;;
  esac
done

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now idle-low-load-shutdown.timer 2>/dev/null || true
  systemctl --user disable --now graceful-shutdown.timer 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
fi

rm -f "${SYSTEMD_USER}/idle-low-load-shutdown.service"
rm -f "${SYSTEMD_USER}/idle-low-load-shutdown.timer"
rm -f "${SYSTEMD_USER}/timers.target.wants/idle-low-load-shutdown.timer"
rm -f "${SYSTEMD_USER}/graceful-shutdown.service"
rm -f "${SYSTEMD_USER}/graceful-shutdown.timer"
rm -f "${SYSTEMD_USER}/timers.target.wants/graceful-shutdown.timer"
rm -f "${BIN}/idle-low-load-shutdown"
rm -f "${BIN}/verify-graceful-shutdown"
rm -rf "${LIB_DIR}"

if [[ "${PURGE_CONFIG}" -eq 1 ]]; then
  rm -f "${CFG_DIR}/config" "${CFG_DIR}/inhibit"
  rmdir "${CFG_DIR}" 2>/dev/null || true
  echo "Removed config under ${CFG_DIR}."
else
  echo "Config kept at ${CFG_DIR}/config (delete manually or re-run with --purge-config)."
fi

echo "Removed idle-low-load-shutdown, verify-graceful-shutdown, graceful-shutdown-lib, and legacy graceful-shutdown user units."
