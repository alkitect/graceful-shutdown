#!/usr/bin/env bash
# CPU/GPU load helpers (sourced by idle-low-load-shutdown; functions only).
# Depends on main: log, run_timeout, clear_*, config and LOAD_*/CPU_*/GPU_*/PHASE_* globals.
# Phase mode: set EFFECTIVE_STREAK_SEC before update_load_hysteresis / load_phase_*.
measure_cpu_pct() {
  read_cpu_jiffies() {
    awk '/^cpu / { idle=$5; total=0; for (i=2; i<=NF; i++) total+=$i; print total, idle }' /proc/stat
  }
  local t1 idle1 t2 idle2 dt didle
  read -r t1 idle1 < <(read_cpu_jiffies)
  sleep "${CPU_SAMPLE_SEC}"
  read -r t2 idle2 < <(read_cpu_jiffies)
  dt=$(( t2 - t1 ))
  didle=$(( idle2 - idle1 ))
  if (( dt <= 0 )); then
    return 1
  fi
  CPU_PCT_RESULT=$(( (100 * (dt - didle)) / dt ))
  return 0
}

measure_gpu_pct() {
  GPU_PCT_RESULT=0
  GPU_VRAM_PCT_RESULT=0

  local glob="/sys/class/drm/card*/device/gpu_busy_percent"
  local sysfs_ok=0
  if [[ -n "${GPU_DRM_CARD}" ]]; then
    glob="/sys/class/drm/${GPU_DRM_CARD}/device/gpu_busy_percent"
  fi

  local f val
  for f in ${glob}; do
    [[ -r "${f}" ]] || continue
    val="$(<"${f}")"
    if [[ "${val}" =~ ^[0-9]+$ ]]; then
      sysfs_ok=1
      if (( val > GPU_PCT_RESULT )); then
        GPU_PCT_RESULT=${val}
      fi
    fi
  done

  if (( sysfs_ok == 0 )) && command -v rocm-smi >/dev/null 2>&1; then
    local rocm_out=""
    rocm_out="$(run_timeout rocm-smi --showuse 2>/dev/null || true)"
    if [[ -z "${rocm_out}" ]]; then
      log "event: load_sample_timeout_or_fail (rocm-smi --showuse)"
    else
      while read -r val; do
        [[ "${val}" =~ ^[0-9]+$ ]] || continue
        if (( val > GPU_PCT_RESULT )); then
          GPU_PCT_RESULT=${val}
        fi
      done < <(printf '%s\n' "${rocm_out}" | grep -oE '[0-9]+%' | tr -d '%' || true)
    fi
  fi

  if [[ "${GPU_CHECK_VRAM}" == "1" ]] && command -v rocm-smi >/dev/null 2>&1; then
    local vram_out="" vram_line
    vram_out="$(run_timeout rocm-smi --showmeminfo vram 2>/dev/null || true)"
    if [[ -z "${vram_out}" ]]; then
      log "event: load_sample_timeout_or_fail (rocm-smi --showmeminfo vram)"
      GPU_VRAM_PCT_RESULT=0
    else
      while read -r vram_line; do
        if [[ "${vram_line}" =~ ([0-9]+)[[:space:]]*% ]]; then
          val="${BASH_REMATCH[1]}"
          if (( val > GPU_VRAM_PCT_RESULT )); then
            GPU_VRAM_PCT_RESULT=${val}
          fi
        fi
      done < <(printf '%s\n' "${vram_out}" | grep -iE 'GPU memory|VRAM' || true)
    fi
  fi
}

load_is_high() {
  if [[ "${CPU_PCT_RESULT}" == "-" || "${GPU_PCT_RESULT}" == "-" ]]; then
    return 1
  fi
  if (( CPU_PCT_RESULT > CPU_MAX_PCT || GPU_PCT_RESULT > GPU_MAX_PCT )); then
    return 0
  fi
  if [[ "${GPU_CHECK_VRAM}" == "1" ]] && [[ "${GPU_VRAM_PCT_RESULT}" != "-" ]] && (( GPU_VRAM_PCT_RESULT > GPU_VRAM_MAX_PCT )); then
    return 0
  fi
  return 1
}

sample_at_or_below_idle_floor() {
  if [[ "${CPU_PCT_RESULT}" == "-" || "${GPU_PCT_RESULT}" == "-" ]]; then
    return 1
  fi
  if (( CPU_PCT_RESULT > CPU_IDLE_PCT || GPU_PCT_RESULT > GPU_IDLE_PCT )); then
    return 1
  fi
  if [[ "${GPU_CHECK_VRAM}" == "1" ]] && [[ "${GPU_VRAM_PCT_RESULT}" != "-" ]] && (( GPU_VRAM_PCT_RESULT > GPU_VRAM_MAX_PCT )); then
    return 1
  fi
  return 0
}

load_gpu_vram_busy() {
  if [[ "${GPU_PCT_RESULT}" == "-" ]]; then
    return 1
  fi
  if (( GPU_PCT_RESULT > GPU_MAX_PCT )); then
    return 0
  fi
  if [[ "${GPU_CHECK_VRAM}" == "1" ]] && [[ "${GPU_VRAM_PCT_RESULT}" != "-" ]] && (( GPU_VRAM_PCT_RESULT > GPU_VRAM_MAX_PCT )); then
    return 0
  fi
  return 1
}

# Append sample. Phase mode always appends + epoch-trims; legacy LOAD_WINDOW uses poll-count trim.
append_load_sample() {
  local phase_on=0
  [[ "${PHASE_LOAD_ENABLED:-0}" == "1" ]] && phase_on=1
  if (( phase_on == 0 )) && [[ "${LOAD_WINDOW_ENABLED}" != "1" ]]; then
    return 0
  fi
  if [[ "${CPU_PCT_RESULT}" == "-" || "${GPU_PCT_RESULT}" == "-" ]]; then
    return 0
  fi
  local high=0
  if (( phase_on == 1 )); then
    if (( CPU_PCT_RESULT > CPU_PHASE_B_SPIKE_MAX_PCT )); then
      high=1
    fi
  elif load_is_high; then
    high=1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s)" \
    "${CPU_PCT_RESULT}" \
    "${GPU_PCT_RESULT}" \
    "${GPU_VRAM_PCT_RESULT}" \
    "${high}" >>"${LOAD_WINDOW_FILE}"

  if (( phase_on == 1 )); then
    trim_load_window_by_epoch
  elif [[ -f "${LOAD_WINDOW_FILE}" ]]; then
    local lines
    lines="$(wc -l <"${LOAD_WINDOW_FILE}")"
    if (( lines > LOAD_WINDOW_POLLS )); then
      tail -n "${LOAD_WINDOW_POLLS}" "${LOAD_WINDOW_FILE}" >"${LOAD_WINDOW_FILE}.tmp"
      mv "${LOAD_WINDOW_FILE}.tmp" "${LOAD_WINDOW_FILE}"
    fi
  fi
}

trim_load_window_by_epoch() {
  [[ -f "${LOAD_WINDOW_FILE}" ]] || return 0
  local now cutoff
  now="$(date +%s)"
  cutoff=$(( now - PHASE_B_WINDOW_SEC ))
  local epoch cpu gpu vram high
  : >"${LOAD_WINDOW_FILE}.tmp"
  while IFS=$'\t' read -r epoch cpu gpu vram high; do
    [[ "${epoch}" =~ ^[0-9]+$ ]] || continue
    if (( epoch >= cutoff )); then
      printf '%s\t%s\t%s\t%s\t%s\n' "${epoch}" "${cpu}" "${gpu}" "${vram}" "${high}" >>"${LOAD_WINDOW_FILE}.tmp"
    fi
  done <"${LOAD_WINDOW_FILE}"
  mv "${LOAD_WINDOW_FILE}.tmp" "${LOAD_WINDOW_FILE}"
}

# Fill WINDOW_* from ring (epoch-trimmed view). Does not decide busy.
load_phase_window_stats() {
  WINDOW_SIZE=0
  WINDOW_HIGH_COUNT=0
  WINDOW_CPU_AVG=0
  WINDOW_GPU_AVG=0
  WINDOW_DISP="-"
  WINDOW_WARMUP=0
  WINDOW_SPIKE=0

  [[ -f "${LOAD_WINDOW_FILE}" ]] || return 1

  local now cutoff cpu_sum=0 gpu_sum=0
  now="$(date +%s)"
  cutoff=$(( now - PHASE_B_WINDOW_SEC ))
  local epoch cpu gpu vram high
  while IFS=$'\t' read -r epoch cpu gpu vram high; do
    [[ "${epoch}" =~ ^[0-9]+$ ]] || continue
    [[ "${cpu}" =~ ^[0-9]+$ ]] || continue
    [[ "${gpu}" =~ ^[0-9]+$ ]] || continue
    if (( epoch < cutoff )); then
      continue
    fi
    WINDOW_SIZE=$(( WINDOW_SIZE + 1 ))
    cpu_sum=$(( cpu_sum + cpu ))
    gpu_sum=$(( gpu_sum + gpu ))
    if (( cpu > CPU_PHASE_B_SPIKE_MAX_PCT )); then
      WINDOW_SPIKE=1
    fi
    if [[ "${high}" == "1" ]]; then
      WINDOW_HIGH_COUNT=$(( WINDOW_HIGH_COUNT + 1 ))
    fi
  done <"${LOAD_WINDOW_FILE}"

  if (( WINDOW_SIZE == 0 )); then
    WINDOW_DISP="0"
    return 1
  fi
  WINDOW_CPU_AVG=$(( cpu_sum / WINDOW_SIZE ))
  WINDOW_GPU_AVG=$(( gpu_sum / WINDOW_SIZE ))
  WINDOW_DISP="${WINDOW_SIZE}s/${PHASE_B_WINDOW_SEC}"
  if (( WINDOW_SIZE < PHASE_B_MIN_SAMPLES )); then
    WINDOW_WARMUP=1
  fi
  return 0
}

# Pure-ish phase busy eval. Uses EFFECTIVE_STREAK_SEC, CPU_PCT_RESULT, ring.
# Sets PHASE_DISP=A|B. Return 0 if busy.
load_phase_eval() {
  local streak="${EFFECTIVE_STREAK_SEC:-0}"
  PHASE_DISP="A"
  WINDOW_CPU_AVG=0
  WINDOW_GPU_AVG=0
  WINDOW_SPIKE=0
  WINDOW_WARMUP=0
  WINDOW_SIZE=0

  if [[ "${CPU_PCT_RESULT}" == "-" || "${GPU_PCT_RESULT}" == "-" ]]; then
    return 0
  fi
  if load_gpu_vram_busy; then
    return 0
  fi

  if (( streak < PHASE_A_SEC )); then
    PHASE_DISP="A"
    if (( CPU_PCT_RESULT > CPU_PHASE_A_MAX_PCT )); then
      return 0
    fi
    return 1
  fi

  PHASE_DISP="B"
  load_phase_window_stats || true

  if (( CPU_PCT_RESULT > CPU_PHASE_A_MAX_PCT )); then
    return 0
  fi
  if (( CPU_PCT_RESULT > CPU_PHASE_B_SPIKE_MAX_PCT )); then
    return 0
  fi
  if (( WINDOW_SPIKE == 1 )); then
    return 0
  fi
  if (( WINDOW_WARMUP == 1 || WINDOW_SIZE < PHASE_B_MIN_SAMPLES )); then
    return 1
  fi
  if (( WINDOW_CPU_AVG > CPU_PHASE_B_MAX_PCT || WINDOW_GPU_AVG > GPU_PHASE_B_MAX_PCT )); then
    return 0
  fi
  return 1
}

# Grace / poweroff: instant critical/spike/GPU only. Fail-closed on sample "-".
# Return 0 if should abort (busy). Does not use Phase B rolling avg or window history.
load_phase_critical_busy() {
  if [[ "${CPU_PCT_RESULT}" == "-" || "${GPU_PCT_RESULT}" == "-" ]]; then
    return 0
  fi
  if load_gpu_vram_busy; then
    return 0
  fi
  if [[ "${PHASE_LOAD_ENABLED:-0}" == "1" ]]; then
    if (( CPU_PCT_RESULT > CPU_PHASE_A_MAX_PCT )); then
      return 0
    fi
    if (( CPU_PCT_RESULT > CPU_PHASE_B_SPIKE_MAX_PCT )); then
      return 0
    fi
    return 1
  fi
  if load_is_high; then
    return 0
  fi
  return 1
}

# Return 0 if soft window is busy. Prefer LOAD_WINDOW_MAX_HIGH when set.
evaluate_load_window() {
  WINDOW_SIZE=0
  WINDOW_HIGH_COUNT=0
  WINDOW_CPU_AVG=0
  WINDOW_GPU_AVG=0
  WINDOW_DISP="-"
  WINDOW_WARMUP=0

  [[ "${LOAD_WINDOW_ENABLED}" == "1" ]] || return 1
  [[ -f "${LOAD_WINDOW_FILE}" ]] || return 1

  local cpu_sum=0 gpu_sum=0 high epoch cpu gpu vram
  while IFS=$'\t' read -r epoch cpu gpu vram high; do
    [[ "${cpu}" =~ ^[0-9]+$ ]] || continue
    [[ "${gpu}" =~ ^[0-9]+$ ]] || continue
    WINDOW_SIZE=$(( WINDOW_SIZE + 1 ))
    cpu_sum=$(( cpu_sum + cpu ))
    gpu_sum=$(( gpu_sum + gpu ))
    if [[ "${high}" == "1" ]]; then
      WINDOW_HIGH_COUNT=$(( WINDOW_HIGH_COUNT + 1 ))
    fi
  done <"${LOAD_WINDOW_FILE}"

  if (( WINDOW_SIZE == 0 )); then
    WINDOW_DISP="0/${LOAD_WINDOW_POLLS}"
    return 1
  fi

  WINDOW_CPU_AVG=$(( cpu_sum / WINDOW_SIZE ))
  WINDOW_GPU_AVG=$(( gpu_sum / WINDOW_SIZE ))
  WINDOW_DISP="${WINDOW_HIGH_COUNT}/${WINDOW_SIZE}"

  if [[ "${LOAD_WINDOW_REQUIRE_FULL}" == "1" ]] && (( WINDOW_SIZE < LOAD_WINDOW_POLLS )); then
    WINDOW_DISP="${WINDOW_SIZE}/${LOAD_WINDOW_POLLS}"
    WINDOW_WARMUP=1
    return 1
  fi

  local frac_busy=0 avg_busy=0 max_high
  if [[ -n "${LOAD_WINDOW_MAX_HIGH:-}" ]] && [[ "${LOAD_WINDOW_MAX_HIGH}" =~ ^[0-9]+$ ]]; then
    max_high="${LOAD_WINDOW_MAX_HIGH}"
  else
    max_high=$(( (WINDOW_SIZE * (100 - LOAD_WINDOW_MIN_OK_FRAC) + 99) / 100 ))
  fi
  if (( WINDOW_HIGH_COUNT > max_high )); then
    frac_busy=1
  fi
  if (( WINDOW_CPU_AVG > CPU_MAX_PCT || WINDOW_GPU_AVG > GPU_MAX_PCT )); then
    avg_busy=1
  fi

  case "${LOAD_WINDOW_METRIC}" in
    avg)
      if (( avg_busy == 1 )); then return 0; fi
      return 1
      ;;
    both)
      if (( frac_busy == 1 || avg_busy == 1 )); then return 0; fi
      return 1
      ;;
    frac|*)
      if (( frac_busy == 1 )); then return 0; fi
      return 1
      ;;
  esac
}

# Raw enter-busy: phase, legacy window, or single-sample high.
load_enter_busy_raw() {
  if [[ "${PHASE_LOAD_ENABLED:-0}" == "1" ]]; then
    if load_phase_eval; then
      return 0
    fi
    return 1
  fi
  if [[ "${LOAD_WINDOW_ENABLED}" == "1" ]]; then
    if evaluate_load_window; then
      return 0
    fi
    return 1
  fi
  if load_is_high; then
    return 0
  fi
  return 1
}

# Leave-busy: phase mode uses inverted enter predicate; legacy uses floors.
load_leave_idle_ok() {
  if [[ "${PHASE_LOAD_ENABLED:-0}" == "1" ]]; then
    if load_enter_busy_raw; then
      return 1
    fi
    return 0
  fi
  sample_at_or_below_idle_floor || return 1
  if [[ "${LOAD_WINDOW_ENABLED}" == "1" ]]; then
    if evaluate_load_window; then
      return 1
    fi
  fi
  return 0
}

# Hysteresis: return 0 while load path should block streak advance.
update_load_hysteresis() {
  local state="idle" ok=0
  [[ -f "${HYSTERESIS_STATE_FILE}" ]] && state="$(<"${HYSTERESIS_STATE_FILE}")"
  [[ -f "${HYSTERESIS_OK_COUNT_FILE}" ]] && ok="$(<"${HYSTERESIS_OK_COUNT_FILE}")"

  if [[ "${state}" != "busy" ]]; then
    if load_enter_busy_raw; then
      echo busy >"${HYSTERESIS_STATE_FILE}"
      echo 0 >"${HYSTERESIS_OK_COUNT_FILE}"
      HYST_DISP="busy"
      return 0
    fi
    echo idle >"${HYSTERESIS_STATE_FILE}"
    echo 0 >"${HYSTERESIS_OK_COUNT_FILE}"
    HYST_DISP="idle"
    return 1
  fi

  # state == busy
  if load_leave_idle_ok; then
    ok=$(( ok + 1 ))
    echo "${ok}" >"${HYSTERESIS_OK_COUNT_FILE}"
    if (( ok >= HYSTERESIS_OK_POLLS )); then
      echo idle >"${HYSTERESIS_STATE_FILE}"
      echo 0 >"${HYSTERESIS_OK_COUNT_FILE}"
      HYST_DISP="idle"
      return 1
    fi
    HYST_DISP="busy_leaving/${ok}"
    return 0
  fi

  echo 0 >"${HYSTERESIS_OK_COUNT_FILE}"
  echo busy >"${HYSTERESIS_STATE_FILE}"
  HYST_DISP="busy"
  return 0
}

refresh_load_status() {
  if [[ "${CPU_PCT_RESULT}" == "-" ]]; then
    LOAD_STATUS="-"
    return
  fi
  if [[ "${PHASE_LOAD_ENABLED:-0}" == "1" ]]; then
    if load_phase_eval; then
      LOAD_STATUS="high"
    else
      LOAD_STATUS="ok"
    fi
    return
  fi
  if load_is_high; then
    LOAD_STATUS="high"
  else
    LOAD_STATUS="ok"
  fi
}

sample_load_if_needed() {
  local force_or_idle="$1"
  if [[ "${LOG_ALWAYS_SAMPLE_LOAD}" == "1" ]] || [[ "${force_or_idle}" == "1" ]]; then
    if measure_cpu_pct; then
      measure_gpu_pct
      refresh_load_status
    else
      CPU_PCT_RESULT="-"
      GPU_PCT_RESULT="-"
      GPU_VRAM_PCT_RESULT="-"
      LOAD_STATUS="-"
      return 1
    fi
  fi
  return 0
}
