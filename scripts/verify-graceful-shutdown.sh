#!/usr/bin/env bash
# Read-only status for graceful-shutdown policy (no poweroff).
set -euo pipefail

CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/graceful-shutdown"
CFG="${CFG_DIR}/config"
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/graceful-shutdown"
FAIL=0

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*" >&2; }
fail() { echo "FAIL: $*" >&2; FAIL=1; }
info() { echo "    $*"; }

echo "=== graceful-shutdown verify ==="

echo ""
echo "=== config ==="
if [[ -f "${CFG}" ]]; then
  ok "${CFG}"
  for key in POWEROFF_ENABLED DRY_RUN INPUT_IDLE_SEC LOW_LOAD_STREAK_SEC CPU_MAX_PCT GPU_MAX_PCT CPU_IDLE_PCT GPU_IDLE_PCT HYSTERESIS_OK_POLLS GRACE_SEC LOAD_WINDOW_ENABLED LOAD_WINDOW_METRIC LOAD_WINDOW_MAX_HIGH NET_CHECK_ENABLED NET_RX_MIN_BPS NET_TX_MIN_BPS NET_BUSY_POLLS BACKUP_CHECK_ENABLED BACKUP_TREAT_UI_PROCESS; do
    grep -E "^[[:space:]]*${key}=" "${CFG}" 2>/dev/null | sed 's/^/    /' || warn "missing ${key}"
  done
else
  fail "config missing — run install-to-local.sh"
fi

echo ""
echo "=== backup (read-only) ==="
if [[ -f "${CFG}" ]] && grep -qE '^[[:space:]]*BACKUP_CHECK_ENABLED=0' "${CFG}" 2>/dev/null; then
  info "BACKUP_CHECK_ENABLED=0 (backup gate off)"
else
  info "BACKUP_CHECK_ENABLED=1 (or default on)"
fi
treat_ui=0
if [[ -f "${CFG}" ]] && grep -qE '^[[:space:]]*BACKUP_TREAT_UI_PROCESS=1' "${CFG}" 2>/dev/null; then
  treat_ui=1
  info "BACKUP_TREAT_UI_PROCESS=1 (legacy: UI process counts as busy)"
else
  info "BACKUP_TREAT_UI_PROCESS=0 (default: unit/duplicity only; UI dialog ignored)"
fi
unit_state="n/a"
if command -v systemctl >/dev/null 2>&1; then
  unit_state="$(systemctl --user is-active deja-dup.service 2>/dev/null || true)"
  info "deja-dup.service: ${unit_state}"
fi
proc_dup=0
proc_ui=0
if command -v pgrep >/dev/null 2>&1; then
  if pgrep -x duplicity >/dev/null 2>&1; then
    proc_dup=1
    info "process: duplicity running (pids $(pgrep -x duplicity | tr '\n' ' '))"
  else
    info "process: duplicity not running"
  fi
  while read -r cmdline; do
    [[ -z "${cmdline}" ]] && continue
    [[ "${cmdline}" == *"--gapplication-service"* ]] && continue
    proc_ui=1
    info "process: deja-dup UI/job (not gapplication-service): ${cmdline}"
    break
  done < <(pgrep -x deja-dup -a 2>/dev/null | sed 's/^[0-9][0-9]*[[:space:]]*//' || true)
  if (( proc_ui == 0 )); then
    if pgrep -x deja-dup >/dev/null 2>&1; then
      info "process: deja-dup only as --gapplication-service (ignored)"
    else
      info "process: deja-dup not running"
    fi
  fi
fi
gate_busy=0
[[ "${unit_state}" == "active" ]] && gate_busy=1
(( proc_dup == 1 )) && gate_busy=1
if (( treat_ui == 1 && proc_ui == 1 )); then
  gate_busy=1
fi
if (( gate_busy == 1 )); then
  info "policy gate: BUSY (would pause streak)"
elif (( proc_ui == 1 )); then
  info "policy gate: ok/ui_pending (UI alive but not blocking)"
else
  info "policy gate: ok"
fi
if [[ -f "${STATE_DIR}/backup-was-busy.flag" ]]; then
  info "state: backup-was-busy.flag present"
fi
if [[ -f "${STATE_DIR}/backup-ui-pending.flag" ]]; then
  info "state: backup-ui-pending.flag present"
fi

echo ""
echo "=== systemd user timer ==="
if systemctl --user is-enabled idle-low-load-shutdown.timer &>/dev/null; then
  ok "timer enabled ($(systemctl --user is-active idle-low-load-shutdown.timer 2>/dev/null || echo unknown))"
  systemctl --user list-timers idle-low-load-shutdown.timer --no-pager 2>/dev/null | tail -n +2 | sed 's/^/    /' || true
else
  warn "idle-low-load-shutdown.timer not enabled"
fi

echo ""
echo "=== installed script + libs ==="
BIN="${HOME}/.local/bin/idle-low-load-shutdown"
LIB_DIR="${HOME}/.local/bin/graceful-shutdown-lib"
if [[ -x "${BIN}" ]]; then
  ok "${BIN}"
  TOPIC_ROOT="${GS_TOPIC_ROOT:-}"
  if [[ -z "${TOPIC_ROOT}" ]]; then
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${HERE}/idle-low-load-shutdown.sh" && -d "${HERE}/lib" ]]; then
      TOPIC_ROOT="$(cd "${HERE}/.." && pwd)"
    elif [[ -f "${HERE}/../scripts/idle-low-load-shutdown.sh" ]]; then
      TOPIC_ROOT="$(cd "${HERE}/.." && pwd)"
    fi
  fi
  if [[ -z "${TOPIC_ROOT}" ]]; then
    fail "repo root unknown — set GS_TOPIC_ROOT to the clone path"
  else
    REPO_SCRIPT="${TOPIC_ROOT}/scripts/idle-low-load-shutdown.sh"
    REPO_LIB="${TOPIC_ROOT}/scripts/lib"
    if [[ -f "${REPO_SCRIPT}" ]]; then
      bin_hash="$(sha256sum "${BIN}" | awk '{print $1}')"
      repo_hash="$(sha256sum "${REPO_SCRIPT}" | awk '{print $1}')"
      if [[ "${bin_hash}" == "${repo_hash}" ]]; then
        ok "deployed binary matches repo (${bin_hash:0:12}…)"
      else
        fail "deployed binary != repo script (run install-to-local.sh)"
      fi
      if [[ -d "${REPO_LIB}" ]]; then
        for repo_lib in "${REPO_LIB}"/*.sh; do
          [[ -f "${repo_lib}" ]] || continue
          base="$(basename "${repo_lib}")"
          inst_lib="${LIB_DIR}/${base}"
          if [[ ! -f "${inst_lib}" ]]; then
            fail "installed lib missing: ${inst_lib} (run install-to-local.sh)"
            continue
          fi
          rh="$(sha256sum "${repo_lib}" | awk '{print $1}')"
          ih="$(sha256sum "${inst_lib}" | awk '{print $1}')"
          if [[ "${rh}" == "${ih}" ]]; then
            ok "lib ${base} matches repo (${rh:0:12}…)"
          else
            fail "lib ${base} != repo (run install-to-local.sh)"
          fi
        done
      fi
      grep_deployed() {
        local pat="$1"
        grep -qE "${pat}" "${BIN}" 2>/dev/null && return 0
        local f
        for f in "${LIB_DIR}"/*.sh; do
          [[ -f "${f}" ]] || continue
          grep -qE "${pat}" "${f}" 2>/dev/null && return 0
        done
        return 1
      }
      if grep -q 'CHECKER_VERSION=gs-lib-1' "${BIN}"; then
        ok "CHECKER_VERSION=gs-lib-1"
      else
        fail "installed binary missing CHECKER_VERSION=gs-lib-1"
      fi
      if grep_deployed 'net_iface_changed|net_iface'; then
        ok "net iface path present"
      else
        fail "deployed tree missing net iface helpers"
      fi
      if grep_deployed 'backup_ui_pending|BACKUP_UI_PENDING'; then
        ok "backup UI pending path present"
      else
        fail "deployed tree missing backup UI pending path"
      fi
      if grep_deployed 'PAUSE_REASON'; then
        ok "PAUSE_REASON present"
      else
        fail "deployed tree missing PAUSE_REASON"
      fi
    else
      fail "repo script not found at ${REPO_SCRIPT}"
    fi
  fi
else
  fail "idle-low-load-shutdown not in ~/.local/bin"
fi
if [[ ! -x "${HOME}/.local/bin/verify-graceful-shutdown" ]] && [[ "$(basename "${BASH_SOURCE[0]}")" == "verify-graceful-shutdown.sh" ]]; then
  : # running from repo is fine
elif [[ ! -x "${HOME}/.local/bin/verify-graceful-shutdown" ]]; then
  warn "verify-graceful-shutdown not installed in ~/.local/bin"
fi

echo ""
echo "=== state ==="
if [[ -f "${STATE_DIR}/low-load-streak.epoch" ]]; then
  streak_start="$(<"${STATE_DIR}/low-load-streak.epoch")"
  now="$(date +%s)"
  if [[ -f "${STATE_DIR}/streak-pause-start.epoch" ]]; then
    pause_start="$(<"${STATE_DIR}/streak-pause-start.epoch")"
    info "low-load streak: PAUSED at $(( pause_start - streak_start ))s effective (origin ${streak_start})"
  else
    info "low-load streak: $(( now - streak_start ))s (since epoch ${streak_start})"
  fi
else
  info "low-load streak: not running"
fi
if [[ -f "${STATE_DIR}/grace-start.epoch" ]]; then
  grace_start="$(<"${STATE_DIR}/grace-start.epoch")"
  grace_age=$(( $(date +%s) - grace_start ))
  info "grace period: ${grace_age}s elapsed"
else
  info "grace period: inactive"
fi
if [[ -f "${STATE_DIR}/load-hysteresis.state" ]]; then
  info "load hysteresis: $(<"${STATE_DIR}/load-hysteresis.state")"
else
  info "load hysteresis: idle (default)"
fi
if [[ -f "${STATE_DIR}/load-window.tsv" ]]; then
  win_n="$(wc -l <"${STATE_DIR}/load-window.tsv")"
  win_high="$(awk -F'\t' '$5==1 {c++} END {print c+0}' "${STATE_DIR}/load-window.tsv")"
  info "load window: ${win_high}/${win_n} high samples"
else
  info "load window: empty / disabled"
fi
if [[ -f "${STATE_DIR}/net-prev.tsv" ]]; then
  info "net counters: $(tr '\t' ' ' <"${STATE_DIR}/net-prev.tsv")"
  if [[ -f "${STATE_DIR}/net-busy-strikes.count" ]]; then
    info "net busy strikes: $(<"${STATE_DIR}/net-busy-strikes.count")"
  fi
  # Show current default-route iface (read-only hint)
  if command -v ip >/dev/null 2>&1; then
    def_if="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    info "default-route iface now: ${def_if:-unknown}"
  fi
else
  info "net counters: not seeded yet"
fi
if [[ -f "${CFG_DIR}/inhibit" ]]; then
  warn "inhibit file present — policy paused (${CFG_DIR}/inhibit)"
fi

echo ""
echo "=== input idle (read-only) ==="
idletime_ms=""
if gdbus_out="$(
  gdbus call --session \
    --dest org.gnome.Mutter.IdleMonitor \
    --object-path /org/gnome/Mutter/IdleMonitor/Core \
    --method org.gnome.Mutter.IdleMonitor.GetIdletime 2>/dev/null
)"; then
  if [[ "${gdbus_out}" =~ uint64[[:space:]]+([0-9]+) ]]; then
    idletime_ms="${BASH_REMATCH[1]}"
    ok "mutter idletime $(( idletime_ms / 1000 ))s"
  fi
fi
if [[ -z "${idletime_ms}" ]]; then
  warn "mutter idletime unavailable (non-GNOME session bus?)"
fi

echo ""
echo "=== GPU sysfs (read-only) ==="
shopt -s nullglob
for f in /sys/class/drm/card*/device/gpu_busy_percent; do
  info "$(dirname "$(dirname "${f}")"): $(<"${f}")%"
done
shopt -u nullglob

echo ""
echo "=== recent log ==="
if [[ -f "${STATE_DIR}/check.log" ]]; then
  grep -aE 'poll:|event:' "${STATE_DIR}/check.log" | tail -5 | sed 's/^/    /'
else
  info "(no check.log yet)"
fi

echo ""
if [[ "${FAIL}" -eq 0 ]]; then
  echo "Verify finished — no failures."
else
  echo "Verify finished — see FAIL lines above."
  exit 1
fi
