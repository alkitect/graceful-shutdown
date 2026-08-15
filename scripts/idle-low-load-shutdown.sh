#!/usr/bin/env bash
# Graceful shutdown: 1 min no input, then 14 min low CPU/GPU (streak pauses on busy load/net/backup).
# Bulk RX/TX keeps the machine awake for large downloads. Ubuntu Backup (Déjà Dup/duplicity) pauses too.
# Invoked by systemd user timer — do not run manually unless DRY_RUN=1 or POWEROFF_ENABLED=0.
set -euo pipefail
CHECKER_VERSION=gs-lib-1

CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/graceful-shutdown"
CFG="${CFG_DIR}/config"
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/graceful-shutdown"
LOCK_FILE="${STATE_DIR}/check.lock"
STREAK_FILE="${STATE_DIR}/low-load-streak.epoch"
STREAK_PAUSE_FILE="${STATE_DIR}/streak-pause-start.epoch"
GRACE_FILE="${STATE_DIR}/grace-start.epoch"
HIGH_LOAD_STRIKES_FILE="${STATE_DIR}/high-load-strikes.count"
PREV_POLL_FILE="${STATE_DIR}/last-poll.epoch"
STREAK_MILESTONE_FILE="${STATE_DIR}/last-streak-milestone.sec"
IDLE_GATE_FILE="${STATE_DIR}/input-idle-gate.flag"
POLL_GAP_WARNED_FILE="${STATE_DIR}/poll-gap-warned.flag"
SESSION_LOCK_STATE_FILE="${STATE_DIR}/session-locked.state"
LOAD_WINDOW_FILE="${STATE_DIR}/load-window.tsv"
HYSTERESIS_STATE_FILE="${STATE_DIR}/load-hysteresis.state"
HYSTERESIS_OK_COUNT_FILE="${STATE_DIR}/hysteresis-ok.count"
NET_PREV_FILE="${STATE_DIR}/net-prev.tsv"
NET_BUSY_STRIKES_FILE="${STATE_DIR}/net-busy-strikes.count"
NET_WAS_BUSY_FILE="${STATE_DIR}/net-was-busy.flag"
BACKUP_WAS_BUSY_FILE="${STATE_DIR}/backup-was-busy.flag"
BACKUP_UI_PENDING_FILE="${STATE_DIR}/backup-ui-pending.flag"
INHIBIT_TOUCH="${CFG_DIR}/inhibit"

# Defaults (overridden by config file).
POWEROFF_ENABLED=0
INPUT_IDLE_SEC=60
LOW_LOAD_STREAK_SEC=840
CPU_MAX_PCT=10
GPU_MAX_PCT=15
CPU_IDLE_PCT=7
GPU_IDLE_PCT=10
HYSTERESIS_OK_POLLS=2
GPU_VRAM_MAX_PCT=90
GPU_CHECK_VRAM=0
GPU_DRM_CARD=""
HIGH_LOAD_POLLS_TO_RESET=2
GRACE_SEC=120
CPU_SAMPLE_SEC=3
EXT_CMD_TIMEOUT_SEC=5
# Soft load window (0=legacy per-poll with hysteresis).
LOAD_WINDOW_ENABLED=0
LOAD_WINDOW_POLLS=8
LOAD_WINDOW_MIN_OK_FRAC=95
LOAD_WINDOW_MAX_HIGH=1
LOAD_WINDOW_METRIC=avg
LOAD_WINDOW_REQUIRE_FULL=1
# Bulk network stay-awake (bytes/sec, not packets).
NET_CHECK_ENABLED=1
NET_RX_MIN_BPS=204800
NET_TX_MIN_BPS=204800
NET_BUSY_POLLS=2
NET_IFACE=""
# Ubuntu Backup (Déjà Dup / duplicity) stay-awake.
BACKUP_CHECK_ENABLED=1
# 0 = ignore lone deja-dup --backup/--restore (often waits on "Backup Finished" UI).
# 1 = legacy: treat any non-gapplication-service deja-dup as busy.
BACKUP_TREAT_UI_PROCESS=0
LOG_FILE="${STATE_DIR}/check.log"
LOG_TO_JOURNAL=1
LOG_MAX_LINES=2000
LOG_HEARTBEAT=1
LOG_ALWAYS_SAMPLE_LOAD=1
LOG_STREAK_MILESTONE_SEC=120
LOG_POLL_GAP_WARN_SEC=90
DRY_RUN=0

if [[ -f "${CFG}" ]]; then
  # shellcheck source=/dev/null
  source "${CFG}"
fi

if [[ -n "${IDLE_SEC:-}" ]] && [[ "${INPUT_IDLE_SEC}" -eq 60 ]] && [[ "${LOW_LOAD_STREAK_SEC}" -eq 840 ]]; then
  if (( IDLE_SEC > INPUT_IDLE_SEC )); then
    LOW_LOAD_STREAK_SEC=$(( IDLE_SEC - INPUT_IDLE_SEC ))
  fi
fi

TOTAL_IDLE_SEC=$(( INPUT_IDLE_SEC + LOW_LOAD_STREAK_SEC ))

CPU_PCT_RESULT="-"
GPU_PCT_RESULT="-"
GPU_VRAM_PCT_RESULT="-"
LOAD_STATUS="-"
SESSION_ID_RESOLVED=""
WINDOW_SIZE=0
WINDOW_HIGH_COUNT=0
WINDOW_CPU_AVG=0
WINDOW_GPU_AVG=0
WINDOW_DISP="-"
WINDOW_WARMUP=0
HYST_DISP="idle"
NET_RX_BPS=0
NET_TX_BPS=0
NET_BUSY=0
NET_DISP="-"
NET_IFACE_RESOLVED="-"
NET_DIR="none"
NET_STRIKES=0
BACKUP_BUSY=0
BACKUP_DISP="-"
PAUSE_REASON="-"
LOAD_HYST_BLOCKING=0

mkdir -p "${STATE_DIR}" "$(dirname "${LOG_FILE}")"

log() {
  local msg="$1"
  printf '%s %s\n' "$(date -Is)" "${msg}" >>"${LOG_FILE}"
  if [[ "${LOG_TO_JOURNAL}" == "1" ]] && command -v logger >/dev/null 2>&1; then
    logger --tag graceful-shutdown -- "${msg}" || true
  fi
  rotate_log_if_needed
}

rotate_log_if_needed() {
  [[ -f "${LOG_FILE}" ]] || return 0
  local lines
  lines="$(wc -l <"${LOG_FILE}")"
  if (( lines > LOG_MAX_LINES )); then
    tail -n $(( LOG_MAX_LINES / 2 )) "${LOG_FILE}" >"${LOG_FILE}.tmp"
    mv "${LOG_FILE}.tmp" "${LOG_FILE}"
  fi
}

run_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    # -k: kill stuck children if they ignore the first signal
    timeout -k 2 "${EXT_CMD_TIMEOUT_SEC}" "$@"
  else
    "$@"
  fi
}

clear_streak() {
  rm -f "${STREAK_FILE}" "${STREAK_MILESTONE_FILE}" "${STREAK_PAUSE_FILE}"
}

clear_grace() {
  rm -f "${GRACE_FILE}"
}

clear_high_load_strikes() {
  rm -f "${HIGH_LOAD_STRIKES_FILE}"
}

clear_hysteresis() {
  rm -f "${HYSTERESIS_STATE_FILE}" "${HYSTERESIS_OK_COUNT_FILE}"
  HYST_DISP="idle"
}

clear_net_busy_strikes() {
  rm -f "${NET_BUSY_STRIKES_FILE}" "${NET_WAS_BUSY_FILE}"
  NET_BUSY=0
  NET_STRIKES=0
}

clear_backup_busy() {
  rm -f "${BACKUP_WAS_BUSY_FILE}" "${BACKUP_UI_PENDING_FILE}"
  BACKUP_BUSY=0
  BACKUP_DISP="-"
}

clear_load_window() {
  rm -f "${LOAD_WINDOW_FILE}"
  WINDOW_SIZE=0
  WINDOW_HIGH_COUNT=0
  WINDOW_CPU_AVG=0
  WINDOW_GPU_AVG=0
  WINDOW_DISP="-"
  WINDOW_WARMUP=0
}

clear_policy_state() {
  clear_streak
  clear_grace
  clear_high_load_strikes
  clear_hysteresis
  clear_net_busy_strikes
  clear_backup_busy
  rm -f "${IDLE_GATE_FILE}"
  clear_load_window
}

# Prints streak epoch or nothing. Always returns 0 — missing file is normal
# (first poll after input_idle_ok). Do not use `[[ -f ]] && cat`: under set -e,
# a false [[ ]] makes "$(streak_start_epoch)" abort the whole check.
streak_start_epoch() {
  if [[ -f "${STREAK_FILE}" ]]; then
    cat "${STREAK_FILE}"
  fi
}

set_streak_now() {
  date +%s >"${STREAK_FILE}"
  echo 0 >"${STREAK_MILESTONE_FILE}"
  rm -f "${STREAK_PAUSE_FILE}"
}

# Freeze streak clock while busy: shift origin forward on resume.
pause_streak() {
  clear_grace
  if [[ ! -f "${STREAK_FILE}" ]]; then
    return 0
  fi
  if [[ ! -f "${STREAK_PAUSE_FILE}" ]]; then
    date +%s >"${STREAK_PAUSE_FILE}"
    log "event: streak paused reason=${PAUSE_REASON} (cpu=${CPU_PCT_RESULT}% gpu=${GPU_PCT_RESULT}% hyst=${HYST_DISP} net_rx=${NET_RX_BPS}B/s net_tx=${NET_TX_BPS}B/s net_if=${NET_IFACE_RESOLVED} backup=${BACKUP_DISP})"
  fi
}

resume_streak_if_paused() {
  [[ -f "${STREAK_PAUSE_FILE}" ]] || return 0
  if [[ ! -f "${STREAK_FILE}" ]]; then
    rm -f "${STREAK_PAUSE_FILE}"
    return 0
  fi
  local pause_start now start elapsed_paused
  pause_start="$(<"${STREAK_PAUSE_FILE}")"
  now="$(date +%s)"
  start="$(<"${STREAK_FILE}")"
  elapsed_paused=$(( now - pause_start ))
  echo $(( start + elapsed_paused )) >"${STREAK_FILE}"
  rm -f "${STREAK_PAUSE_FILE}"
  log "event: streak resumed (paused ${elapsed_paused}s; origin shifted)"
}

# Effective low-load seconds (frozen while pause file present).
effective_streak_sec() {
  local start now pause_start
  start="$(streak_start_epoch)"
  if [[ -z "${start}" ]]; then
    echo 0
    return
  fi
  now="$(date +%s)"
  if [[ -f "${STREAK_PAUSE_FILE}" ]]; then
    pause_start="$(<"${STREAK_PAUSE_FILE}")"
    echo $(( pause_start - start ))
    return
  fi
  echo $(( now - start ))
}

high_load_strikes() {
  if [[ -f "${HIGH_LOAD_STRIKES_FILE}" ]]; then
    cat "${HIGH_LOAD_STRIKES_FILE}"
  else
    echo 0
  fi
}

mark_poll_now() {
  date +%s >"${PREV_POLL_FILE}"
  rm -f "${POLL_GAP_WARNED_FILE}"
}

warn_poll_gap_if_needed() {
  [[ "${LOG_POLL_GAP_WARN_SEC}" -gt 0 ]] || return 0
  [[ -f "${PREV_POLL_FILE}" ]] || return 0
  [[ -f "${POLL_GAP_WARNED_FILE}" ]] && return 0
  local prev now gap
  prev="$(<"${PREV_POLL_FILE}")"
  now="$(date +%s)"
  gap=$(( now - prev ))
  if (( gap > LOG_POLL_GAP_WARN_SEC )); then
    log "event: poll_gap ${gap}s (no completed poll since $(date -Is -d "@${prev}" 2>/dev/null || echo "epoch ${prev}"))"
    touch "${POLL_GAP_WARNED_FILE}"
  fi
}

maybe_event_streak_progress() {
  local streak_sec="$1"
  [[ "${LOG_STREAK_MILESTONE_SEC}" -gt 0 ]] || return 0
  local last=0 milestone
  [[ -f "${STREAK_MILESTONE_FILE}" ]] && last="$(<"${STREAK_MILESTONE_FILE}")"
  milestone=$(( (streak_sec / LOG_STREAK_MILESTONE_SEC) * LOG_STREAK_MILESTONE_SEC ))
  if (( milestone > 0 && milestone > last && milestone < LOW_LOAD_STREAK_SEC )); then
    log "event: streak progress ${milestone}s/${LOW_LOAD_STREAK_SEC}s"
    echo "${milestone}" >"${STREAK_MILESTONE_FILE}"
  fi
}

log_poll() {
  local decision="$1"
  local idle_disp="$2"
  local source_disp="$3"
  local streak_disp="$4"
  local grace_disp="$5"
  local strikes_disp="$6"
  local extra=""

  [[ "${LOG_HEARTBEAT}" == "1" ]] || return 0

  if [[ "${LOAD_WINDOW_ENABLED}" == "1" ]]; then
    extra+=" win=${WINDOW_DISP}"
  fi
  extra+=" hyst=${HYST_DISP}"
  if [[ "${NET_CHECK_ENABLED}" == "1" ]]; then
    extra+=" net_rx=${NET_RX_BPS}B/s net_tx=${NET_TX_BPS}B/s"
    extra+=" net_rx_min=${NET_RX_MIN_BPS}B/s net_tx_min=${NET_TX_MIN_BPS}B/s"
    extra+=" net_dir=${NET_DIR} net_strikes=${NET_STRIKES}/${NET_BUSY_POLLS}"
    extra+=" net_if=${NET_IFACE_RESOLVED} net=${NET_DISP}"
  fi
  if [[ "${BACKUP_CHECK_ENABLED}" == "1" ]]; then
    extra+=" backup=${BACKUP_DISP}"
  fi
  if [[ "${decision}" == "streak_paused" && "${PAUSE_REASON}" != "-" ]]; then
    extra+=" reason=${PAUSE_REASON}"
  fi

  log "poll: idle=${idle_disp}s source=${source_disp} cpu=${CPU_PCT_RESULT}% gpu=${GPU_PCT_RESULT}% vram=${GPU_VRAM_PCT_RESULT}% load=${LOAD_STATUS} streak=${streak_disp} grace=${grace_disp} strikes=${strikes_disp}${extra} decision=${decision}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_gs_lib() {
  local name="$1" f
  for f in     "${SCRIPT_DIR}/lib/${name}"     "${SCRIPT_DIR}/graceful-shutdown-lib/${name}"     "${HOME}/.local/bin/graceful-shutdown-lib/${name}"     ${GS_TOPIC_ROOT:+"${GS_TOPIC_ROOT}/scripts/lib/${name}"}; do
    [[ -n "${f}" && -f "${f}" ]] || continue
    # shellcheck disable=SC1090
    source "${f}"
    return 0
  done
  return 1
}
for _gs_lib in idle.sh load.sh net.sh backup.sh; do
  if ! source_gs_lib "${_gs_lib}"; then
    echo "idle-low-load-shutdown: missing lib/${_gs_lib}" >&2
    exit 1
  fi
done
unset _gs_lib

policy_is_blocking() {
  local load_b=0 net_b=0 backup_b=0
  local parts=()
  PAUSE_REASON="-"
  if update_load_hysteresis; then
    load_b=1
  fi
  if net_is_busy; then
    net_b=1
  fi
  if backup_is_busy; then
    backup_b=1
  fi
  (( load_b == 1 )) && parts+=("load")
  (( net_b == 1 )) && parts+=("net")
  (( backup_b == 1 )) && parts+=("backup")
  if (( ${#parts[@]} == 0 )); then
    return 1
  fi
  local IFS='+'
  PAUSE_REASON="${parts[*]}"
  return 0
}

current_streak_disp() {
  local start sec
  start="$(streak_start_epoch)"
  if [[ -z "${start}" ]]; then
    echo "-"
    return
  fi
  sec="$(effective_streak_sec)"
  if [[ -f "${STREAK_PAUSE_FILE}" ]]; then
    echo "${sec}s(paused)"
  else
    echo "${sec}s"
  fi
}

current_grace_disp() {
  if [[ ! -f "${GRACE_FILE}" ]]; then
    echo "-"
    return
  fi
  local start now
  start="$(<"${GRACE_FILE}")"
  now="$(date +%s)"
  echo "$(( now - start ))s"
}

send_grace_notification() {
  local remaining="$1"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical "Shutting down soon" \
      "No input for 15+ min and load is low. Powering off in ${remaining}s unless you move the mouse or press a key."
  fi
}

run_check() {
  warn_poll_gap_if_needed
  maybe_log_session_lock_change

  if [[ -f "${INHIBIT_TOUCH}" ]]; then
    log_poll "inhibit" "-" "n/a" "-" "-" "0"
    log "event: inhibit file present (${INHIBIT_TOUCH})"
    mark_poll_now
    clear_policy_state
    exit 0
  fi

  local idle_rc=0
  measure_input_idle || idle_rc=$?
  if (( idle_rc != 0 )); then
    case "${idle_rc}" in
      1) log_poll "no_idle_source" "0" "none" "-" "-" "0"
         log "event: no input idle source (mutter unavailable, no session)" ;;
      2) log_poll "not_idle" "0" "loginctl" "-" "-" "0"
         log "event: not idle (loginctl)" ;;
      *) log_poll "idle_error" "0" "unknown" "-" "-" "0"
         log "event: input idle measurement failed (rc=${idle_rc})" ;;
    esac
    mark_poll_now
    clear_policy_state
    exit 0
  fi

  local input_idle_sec="${INPUT_IDLE_SEC_RESULT}"
  local idle_source="${IDLE_SOURCE_RESULT}"

  mark_poll_now
  maybe_event_input_idle_ok "${input_idle_sec}"
  measure_net_bps
  measure_backup_busy

  if (( input_idle_sec < INPUT_IDLE_SEC )); then
    sample_load_if_needed 0 || true
    log_poll "wait_input_idle" "${input_idle_sec}" "${idle_source}" "-" "-" "0"
    clear_policy_state
    exit 0
  fi

  if ! sample_load_if_needed 1; then
    log_poll "cpu_sample_invalid" "${input_idle_sec}" "${idle_source}" "-" "-" "0"
    exit 0
  fi

  append_load_sample
  evaluate_load_window || true

  if [[ "${LOAD_WINDOW_ENABLED}" == "1" && "${WINDOW_WARMUP}" == "1" ]]; then
    clear_high_load_strikes
    clear_streak
    clear_grace
    log_poll "window_warmup" "${input_idle_sec}" "${idle_source}" "-" "-" "0"
    exit 0
  fi

  if policy_is_blocking; then
    pause_streak
    log_poll "streak_paused" "${input_idle_sec}" "${idle_source}" "$(current_streak_disp)" "-" "0"
    exit 0
  fi

  resume_streak_if_paused
  clear_high_load_strikes

  local now_epoch streak_start streak_sec
  now_epoch="$(date +%s)"
  streak_start="$(streak_start_epoch)"
  if [[ -z "${streak_start}" ]]; then
    set_streak_now
    streak_start="${now_epoch}"
    log "event: streak started (idle=${input_idle_sec}s cpu=${CPU_PCT_RESULT}% gpu=${GPU_PCT_RESULT}% net_rx=${NET_RX_BPS}B/s)"
  fi

  streak_sec="$(effective_streak_sec)"
  maybe_event_streak_progress "${streak_sec}"

  if (( streak_sec < LOW_LOAD_STREAK_SEC )); then
    clear_grace
    log_poll "streak_wait" "${input_idle_sec}" "${idle_source}" "${streak_sec}s" "-" "0"
    exit 0
  fi

  if (( input_idle_sec < TOTAL_IDLE_SEC )); then
    clear_grace
    log_poll "wait_total_idle" "${input_idle_sec}" "${idle_source}" "${streak_sec}s" "-" "0"
    exit 0
  fi

  if command -v systemd-inhibit >/dev/null 2>&1; then
    local inhibit_shutdown_block
    inhibit_shutdown_block="$(
      systemd-inhibit --list --no-pager 2>/dev/null | awk '
        NR > 2 && $0 !~ /^[[:space:]]*$/ {
          if ($0 ~ /shutdown/ && $0 ~ /block/) n++
        }
        END { print n + 0 }
      '
    )"
    if (( inhibit_shutdown_block > 0 )); then
      clear_grace
      log_poll "inhibit_shutdown" "${input_idle_sec}" "${idle_source}" "${streak_sec}s" "-" "0"
      log "event: ${inhibit_shutdown_block} shutdown block inhibitor(s)"
      exit 0
    fi
  fi

  log_poll "eligible" "${input_idle_sec}" "${idle_source}" "${streak_sec}s" "$(current_grace_disp)" "0"
  log "event: eligible (idle=${input_idle_sec}s streak=${streak_sec}s cpu=${CPU_PCT_RESULT}% gpu=${GPU_PCT_RESULT}% net_rx=${NET_RX_BPS}B/s)"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "event: dry-run would enter grace or power off"
    exit 0
  fi

  if [[ "${POWEROFF_ENABLED}" != "1" ]]; then
    log "event: POWEROFF_ENABLED=${POWEROFF_ENABLED}"
    exit 0
  fi

  local grace_start grace_elapsed grace_remaining
  if [[ ! -f "${GRACE_FILE}" ]]; then
    date +%s >"${GRACE_FILE}"
    send_grace_notification "${GRACE_SEC}"
    log_poll "grace_start" "${input_idle_sec}" "${idle_source}" "${streak_sec}s" "0s" "0"
    log "event: grace warning sent (${GRACE_SEC}s until poweroff)"
    exit 0
  fi

  grace_start="$(<"${GRACE_FILE}")"
  grace_elapsed=$(( now_epoch - grace_start ))
  grace_remaining=$(( GRACE_SEC - grace_elapsed ))

  if (( grace_elapsed < GRACE_SEC )); then
    measure_input_idle || idle_rc=$?
    if (( idle_rc != 0 )) || (( INPUT_IDLE_SEC_RESULT < INPUT_IDLE_SEC )); then
      log "event: grace cancelled (user active)"
      clear_policy_state
      exit 0
    fi
    input_idle_sec="${INPUT_IDLE_SEC_RESULT}"
    measure_net_bps
    measure_backup_busy
    if ! sample_load_if_needed 1; then
      exit 0
    fi
    if load_is_high || net_sample_is_bulk || backup_is_busy; then
      log "event: grace cancelled (load/net/backup busy cpu=${CPU_PCT_RESULT}% gpu=${GPU_PCT_RESULT}% net_rx=${NET_RX_BPS}B/s net_tx=${NET_TX_BPS}B/s backup=${BACKUP_DISP})"
      clear_policy_state
      exit 0
    fi
    log_poll "grace_wait" "${input_idle_sec}" "${idle_source}" "${streak_sec}s" "${grace_elapsed}s" "0"
    log "event: grace waiting ${grace_remaining}s"
    exit 0
  fi

  measure_input_idle || idle_rc=$?
  if (( idle_rc != 0 )) || (( INPUT_IDLE_SEC_RESULT < TOTAL_IDLE_SEC )); then
    log "event: grace expired but user active — aborting poweroff"
    clear_policy_state
    exit 0
  fi
  input_idle_sec="${INPUT_IDLE_SEC_RESULT}"
  measure_net_bps
  measure_backup_busy
  if ! sample_load_if_needed 1; then
    exit 0
  fi
  if load_is_high || net_sample_is_bulk || backup_is_busy; then
    log "event: grace expired but load/net/backup busy — aborting poweroff"
    clear_policy_state
    exit 0
  fi

  log_poll "poweroff" "${input_idle_sec}" "${idle_source}" "${streak_sec}s" "${grace_elapsed}s" "0"
  log "event: action systemctl poweroff"
  clear_policy_state
  exec /usr/bin/systemctl poweroff
}

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  log "poll: decision=flock_busy"
  exit 0
fi

# Log unexpected errexit (e.g. set -e traps) so journal Failed is not silent.
trap 'rc=$?; log "event: unexpected_exit rc=${rc} line=${LINENO} cmd=${BASH_COMMAND}" || true' ERR

run_check
