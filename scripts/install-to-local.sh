#!/usr/bin/env bash
# Install idle-low-load shutdown checker; remove legacy broken graceful-shutdown timer.
# Usage: install-to-local.sh [--enable-automation]
# Does NOT run the checker script (avoids accidental shutdown during setup).
# Call aw_snapshot_units at install START (before overwriting units).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/automation-wanted.sh
source "${ROOT}/scripts/lib/automation-wanted.sh"

BIN="${HOME}/.local/bin"
CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/graceful-shutdown"
SYSTEMD_USER="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
LIB_DIR="${BIN}/graceful-shutdown-lib"
ENABLE_AUTOMATION=0
TIMER_UNIT="idle-low-load-shutdown.timer"

for arg in "$@"; do
  case "${arg}" in
    --enable-automation) ENABLE_AUTOMATION=1 ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--enable-automation]"
      echo "  Installs checker + libs + units. Does not execute the checker."
      echo "  Set POWEROFF_ENABLED=1 in config before --enable-automation."
      echo "  Restores timer if previously enabled, automation.wanted exists, or POWEROFF_ENABLED=1."
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      exit 2
      ;;
  esac
done

# Snapshot before overwrite/daemon-reload.
aw_snapshot_units "${TIMER_UNIT}"

mkdir -p "${BIN}" "${CFG_DIR}" "${SYSTEMD_USER}" "${LIB_DIR}"

install -m0755 "${ROOT}/scripts/idle-low-load-shutdown.sh" "${BIN}/idle-low-load-shutdown"
install -m0755 "${ROOT}/scripts/verify-graceful-shutdown.sh" "${BIN}/verify-graceful-shutdown"
for lib in "${ROOT}/scripts/lib/"*.sh; do
  base="$(basename "${lib}")"
  # Host automation helper is sourced by install only; not a checker policy lib.
  [[ "${base}" == "automation-wanted.sh" ]] && continue
  install -m0644 "${lib}" "${LIB_DIR}/${base}"
done

if [[ ! -f "${CFG_DIR}/config" ]]; then
  install -m0644 "${ROOT}/config/example.config" "${CFG_DIR}/config"
  echo "Seeded ${CFG_DIR}/config (POWEROFF_ENABLED=0)"
else
  echo "Keeping existing ${CFG_DIR}/config"
  PHASE_APPENDED=0
  for key in PHASE_LOAD_ENABLED PHASE_A_SEC CPU_PHASE_A_MAX_PCT PHASE_B_WINDOW_SEC CPU_PHASE_B_MAX_PCT GPU_PHASE_B_MAX_PCT CPU_PHASE_B_SPIKE_MAX_PCT INPUT_IDLE_SEC LOW_LOAD_STREAK_SEC CPU_MAX_PCT GPU_MAX_PCT CPU_IDLE_PCT GPU_IDLE_PCT HYSTERESIS_OK_POLLS GPU_DRM_CARD GPU_CHECK_VRAM GPU_VRAM_MAX_PCT HIGH_LOAD_POLLS_TO_RESET GRACE_SEC CPU_SAMPLE_SEC EXT_CMD_TIMEOUT_SEC LOAD_WINDOW_ENABLED LOAD_WINDOW_POLLS LOAD_WINDOW_MIN_OK_FRAC LOAD_WINDOW_MAX_HIGH LOAD_WINDOW_METRIC LOAD_WINDOW_REQUIRE_FULL NET_CHECK_ENABLED NET_RX_MIN_BPS NET_TX_MIN_BPS NET_BUSY_POLLS NET_IFACE BACKUP_CHECK_ENABLED BACKUP_TREAT_UI_PROCESS LOG_TO_JOURNAL LOG_MAX_LINES LOG_HEARTBEAT LOG_ALWAYS_SAMPLE_LOAD LOG_STREAK_MILESTONE_SEC LOG_POLL_GAP_WARN_SEC DRY_RUN; do
    if ! grep -qE "^[[:space:]]*${key}=" "${CFG_DIR}/config" 2>/dev/null; then
      grep "^${key}=" "${ROOT}/config/example.config" >>"${CFG_DIR}/config" || true
      echo "  appended ${key} from example.config"
      case "${key}" in
        PHASE_*) PHASE_APPENDED=1 ;;
      esac
    fi
  done
  if [[ "${PHASE_APPENDED}" -eq 1 ]]; then
    STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/graceful-shutdown"
    rm -f "${STATE_DIR}/load-window.tsv"
    echo ""
    echo "Phase load keys were added (default PHASE_LOAD_ENABLED=1)."
    echo "  Cleared ${STATE_DIR}/load-window.tsv if present (drop legacy 10% marks)."
    echo "  Kill-switches: touch ${CFG_DIR}/inhibit | PHASE_LOAD_ENABLED=0 | POWEROFF_ENABLED=0 |"
    echo "  systemctl --user stop idle-low-load-shutdown.timer | unlock or move input."
    if grep -qE '^[[:space:]]*POWEROFF_ENABLED=1' "${CFG_DIR}/config" 2>/dev/null; then
      echo "  POWEROFF_ENABLED=1: run DRY_RUN=1 ~/.local/bin/idle-low-load-shutdown a few times before relying on the timer."
    fi
    echo "  See README Limits and docs/IMPLEMENTATION.md § Migration."
  fi
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
if [[ -z "${ALKITECT_CI_TMP:-}" ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now graceful-shutdown.timer 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
fi
rm -f "${LEGACY_TIMER}" "${LEGACY_SERVICE}"
rm -f "${SYSTEMD_USER}/timers.target.wants/graceful-shutdown.timer"

if [[ -z "${ALKITECT_CI_TMP:-}" ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload
elif [[ -n "${ALKITECT_CI_TMP:-}" ]]; then
  echo "ALKITECT_CI_TMP=1: skipped systemctl (unit files under tmp HOME only)"
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
echo "  systemctl --user enable --now ${TIMER_UNIT}"
echo "Log: \${XDG_STATE_HOME:-\$HOME/.local/state}/graceful-shutdown/check.log"

AW_ARMED_CONFIG=0
if grep -qE '^[[:space:]]*POWEROFF_ENABLED=1' "${CFG_DIR}/config" 2>/dev/null; then
  AW_ARMED_CONFIG=1
fi

do_enable() {
  local why="$1"
  AW_FORCE_ENABLE=0
  if [[ -n "${ALKITECT_CI_TMP:-}" ]]; then
    aw_enable_units "${why}" "${TIMER_UNIT}"
    aw_mark_wanted "${CFG_DIR}"
    return 0
  fi
  aw_enable_units "${why}" "${TIMER_UNIT}"
  aw_mark_wanted "${CFG_DIR}"
  echo "Timer enabled. Checker runs on schedule only — not invoked now."
}

if [[ "${ENABLE_AUTOMATION}" -eq 1 ]]; then
  if [[ "${AW_ARMED_CONFIG}" -ne 1 ]]; then
    echo "" >&2
    echo "Refusing --enable-automation: POWEROFF_ENABLED is not 1 in ${CFG_DIR}/config" >&2
    exit 1
  fi
  do_enable "--enable-automation"
elif aw_should_restore "${CFG_DIR}"; then
  do_enable "restored (snapshot/marker/POWEROFF_ENABLED=1)"
elif [[ -z "${ALKITECT_CI_TMP:-}" ]] && command -v systemctl >/dev/null 2>&1; then
  if [[ "${AW_ARMED_CONFIG}" -eq 1 ]] \
    && ! systemctl --user is-enabled "${TIMER_UNIT}" >/dev/null 2>&1; then
    # Should not happen if aw_should_restore works; keep as last-resort notice.
    echo "" >&2
    echo "WARNING: POWEROFF_ENABLED=1 but ${TIMER_UNIT} is disabled and restore did not run." >&2
  fi
fi
