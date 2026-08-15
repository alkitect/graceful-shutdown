#!/usr/bin/env bash
# Install idle-low-load shutdown checker; remove legacy broken graceful-shutdown timer.
# Usage: install-to-local.sh [--enable-automation]
# Does NOT run the checker script (avoids accidental shutdown during setup).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${HOME}/.local/bin"
CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/graceful-shutdown"
SYSTEMD_USER="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
LIB_DIR="${BIN}/graceful-shutdown-lib"
ENABLE_AUTOMATION=0

for arg in "$@"; do
  case "${arg}" in
    --enable-automation) ENABLE_AUTOMATION=1 ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--enable-automation]"
      echo "  Installs checker + libs + units. Does not execute the checker."
      echo "  Set POWEROFF_ENABLED=1 in config before --enable-automation."
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      exit 2
      ;;
  esac
done

mkdir -p "${BIN}" "${CFG_DIR}" "${SYSTEMD_USER}" "${LIB_DIR}"

install -m0755 "${ROOT}/scripts/idle-low-load-shutdown.sh" "${BIN}/idle-low-load-shutdown"
install -m0755 "${ROOT}/scripts/verify-graceful-shutdown.sh" "${BIN}/verify-graceful-shutdown"
for lib in "${ROOT}/scripts/lib/"*.sh; do
  install -m0644 "${lib}" "${LIB_DIR}/$(basename "${lib}")"
done

if [[ ! -f "${CFG_DIR}/config" ]]; then
  install -m0644 "${ROOT}/config/example.config" "${CFG_DIR}/config"
  echo "Seeded ${CFG_DIR}/config (POWEROFF_ENABLED=0)"
else
  echo "Keeping existing ${CFG_DIR}/config"
  for key in INPUT_IDLE_SEC LOW_LOAD_STREAK_SEC CPU_MAX_PCT GPU_MAX_PCT CPU_IDLE_PCT GPU_IDLE_PCT HYSTERESIS_OK_POLLS GPU_DRM_CARD GPU_CHECK_VRAM GPU_VRAM_MAX_PCT HIGH_LOAD_POLLS_TO_RESET GRACE_SEC CPU_SAMPLE_SEC EXT_CMD_TIMEOUT_SEC LOAD_WINDOW_ENABLED LOAD_WINDOW_POLLS LOAD_WINDOW_MIN_OK_FRAC LOAD_WINDOW_MAX_HIGH LOAD_WINDOW_METRIC LOAD_WINDOW_REQUIRE_FULL NET_CHECK_ENABLED NET_RX_MIN_BPS NET_TX_MIN_BPS NET_BUSY_POLLS NET_IFACE BACKUP_CHECK_ENABLED BACKUP_TREAT_UI_PROCESS LOG_TO_JOURNAL LOG_MAX_LINES LOG_HEARTBEAT LOG_ALWAYS_SAMPLE_LOAD LOG_STREAK_MILESTONE_SEC LOG_POLL_GAP_WARN_SEC DRY_RUN; do
    if ! grep -qE "^[[:space:]]*${key}=" "${CFG_DIR}/config" 2>/dev/null; then
      grep "^${key}=" "${ROOT}/config/example.config" >>"${CFG_DIR}/config" || true
      echo "  appended ${key} from example.config"
    fi
  done
fi

for unit in service timer; do
  src="${ROOT}/systemd/user/idle-low-load-shutdown.${unit}.example"
  dest="${SYSTEMD_USER}/idle-low-load-shutdown.${unit}"
  install -m0644 "${src}" "${dest}"
  echo "Installed ${dest}"
done

# Remove legacy timer that powered off every 15 min regardless of idle.
LEGACY_TIMER="${SYSTEMD_USER}/graceful-shutdown.timer"
LEGACY_SERVICE="${SYSTEMD_USER}/graceful-shutdown.service"
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now graceful-shutdown.timer 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
fi
rm -f "${LEGACY_TIMER}" "${LEGACY_SERVICE}"
rm -f "${SYSTEMD_USER}/timers.target.wants/graceful-shutdown.timer"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload
fi

echo ""
echo "Installed:"
echo "  ${BIN}/idle-low-load-shutdown"
echo "  ${BIN}/verify-graceful-shutdown"
echo "  ${LIB_DIR}/*.sh"
echo "  ${CFG_DIR}/config"
echo "  ${SYSTEMD_USER}/idle-low-load-shutdown.{service,timer}"
echo ""
echo "Legacy graceful-shutdown.timer removed/disabled."
echo ""
echo "Before enabling:"
echo "  1. Review ${CFG_DIR}/config"
echo "  2. Set POWEROFF_ENABLED=1 when ready"
echo "  3. Optional: DRY_RUN=1 for a few polling cycles (check log)"
echo ""
echo "Enable polling (does not run checker now):"
echo "  systemctl --user enable --now idle-low-load-shutdown.timer"
echo "Log: \${XDG_STATE_HOME:-\$HOME/.local/state}/graceful-shutdown/check.log"

if [[ "${ENABLE_AUTOMATION}" -eq 1 ]]; then
  if ! grep -qE '^[[:space:]]*POWEROFF_ENABLED=1' "${CFG_DIR}/config" 2>/dev/null; then
    echo "" >&2
    echo "Refusing --enable-automation: POWEROFF_ENABLED is not 1 in ${CFG_DIR}/config" >&2
    exit 1
  fi
  echo ""
  echo "Enabling idle-low-load-shutdown.timer (--enable-automation)..."
  systemctl --user enable --now idle-low-load-shutdown.timer
  echo "Timer enabled. Checker runs on schedule only — not invoked now."
fi
