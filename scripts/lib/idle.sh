#!/usr/bin/env bash
# Idle measurement helpers (sourced by idle-low-load-shutdown; functions only).
# Depends on main globals: log, run_timeout, SESSION_*, INPUT_IDLE_SEC_RESULT, IDLE_SOURCE_RESULT
resolve_session_id() {
  if [[ -n "${SESSION_ID_RESOLVED}" ]]; then
    echo "${SESSION_ID_RESOLVED}"
    return 0
  fi
  local sid="${XDG_SESSION_ID:-}"
  if [[ -z "${sid}" ]]; then
    sid="$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$(id -un)" '$3 == u { print $1; exit }')"
  fi
  SESSION_ID_RESOLVED="${sid}"
  echo "${sid}"
}

maybe_log_session_lock_change() {
  local sid locked prev="unknown"
  sid="$(resolve_session_id)"
  [[ -n "${sid}" ]] || return 0
  locked="$(loginctl show-session "${sid}" -p LockedHint --value 2>/dev/null || true)"
  [[ "${locked}" == "yes" || "${locked}" == "no" ]] || return 0
  [[ -f "${SESSION_LOCK_STATE_FILE}" ]] && prev="$(<"${SESSION_LOCK_STATE_FILE}")"
  if [[ "${locked}" == "yes" && "${prev}" != "yes" ]]; then
    log "event: session_locked (session=${sid})"
  elif [[ "${locked}" == "no" && "${prev}" == "yes" ]]; then
    log "event: session_unlocked (session=${sid})"
  fi
  echo "${locked}" >"${SESSION_LOCK_STATE_FILE}"
}

measure_input_idle_loginctl() {
  local session_id idle_hint idle_since now_usec
  session_id="$(resolve_session_id)"
  if [[ -z "${session_id}" ]]; then
    return 1
  fi
  idle_hint="$(loginctl show-session "${session_id}" -p IdleHint --value 2>/dev/null || true)"
  idle_since="$(loginctl show-session "${session_id}" -p IdleSinceHint --value 2>/dev/null || true)"
  if [[ "${idle_hint}" != "yes" || -z "${idle_since}" || "${idle_since}" == "0" ]]; then
    return 2
  fi
  now_usec="$(date +%s%6N)"
  IDLE_SOURCE_RESULT="loginctl"
  INPUT_IDLE_SEC_RESULT=$(( (now_usec - idle_since) / 1000000 ))
  return 0
}

measure_input_idle_mutter() {
  local gdbus_out input_idle_ms=""
  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && [[ ! -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ]]; then
    return 1
  fi
  gdbus_out="$(
    run_timeout gdbus call --session \
      --dest org.gnome.Mutter.IdleMonitor \
      --object-path /org/gnome/Mutter/IdleMonitor/Core \
      --method org.gnome.Mutter.IdleMonitor.GetIdletime 2>/dev/null || true
  )"
  if [[ "${gdbus_out}" =~ uint64[[:space:]]+([0-9]+) ]]; then
    input_idle_ms="${BASH_REMATCH[1]}"
  fi
  [[ -n "${input_idle_ms}" ]] || return 1
  IDLE_SOURCE_RESULT="mutter"
  INPUT_IDLE_SEC_RESULT=$(( input_idle_ms / 1000 ))
  return 0
}

measure_input_idle() {
  INPUT_IDLE_SEC_RESULT=0
  IDLE_SOURCE_RESULT="unknown"

  # When locked, prefer loginctl first (Mutter can be flaky on the lock screen).
  local sid locked=""
  sid="$(resolve_session_id)"
  if [[ -n "${sid}" ]]; then
    locked="$(loginctl show-session "${sid}" -p LockedHint --value 2>/dev/null || true)"
  fi
  if [[ "${locked}" == "yes" ]]; then
    if measure_input_idle_loginctl; then
      return 0
    fi
    if measure_input_idle_mutter; then
      return 0
    fi
    return 1
  fi

  if measure_input_idle_mutter; then
    return 0
  fi
  measure_input_idle_loginctl
}

maybe_event_input_idle_ok() {
  local idle_sec="$1"
  if (( idle_sec >= INPUT_IDLE_SEC )); then
    if [[ ! -f "${IDLE_GATE_FILE}" ]]; then
      log "event: input_idle_ok (idle=${idle_sec}s >= ${INPUT_IDLE_SEC}s)"
      touch "${IDLE_GATE_FILE}"
    fi
  else
    rm -f "${IDLE_GATE_FILE}"
  fi
}
