#!/usr/bin/env bash
# Network bulk helpers (sourced by idle-low-load-shutdown; functions only).
# Depends on main: log, clear_net_busy_strikes, NET_* globals
resolve_net_iface() {
  local dev=""
  if [[ -n "${NET_IFACE}" ]]; then
    echo "${NET_IFACE}"
    return 0
  fi
  if command -v ip >/dev/null 2>&1; then
    dev="$(
      ip -4 route get 1.1.1.1 2>/dev/null | awk '{
        for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }
      }'
    )"
    if [[ -n "${dev}" && "${dev}" != "lo" ]]; then
      echo "${dev}"
      return 0
    fi
  fi
  # Fallback: busiest non-lo by absolute rx+tx (single iface, not sum).
  local best_iface="" best_tot=-1 iface r t tot
  while read -r line; do
    [[ "${line}" == *":"* ]] || continue
    iface="${line%%:*}"
    iface="${iface#"${iface%%[![:space:]]*}"}"
    iface="${iface%"${iface##*[![:space:]]}"}"
    [[ "${iface}" == "lo" || -z "${iface}" ]] && continue
    read -r r _ _ _ _ _ _ _ t _ <<<"${line#*:}"
    [[ "${r}" =~ ^[0-9]+$ && "${t}" =~ ^[0-9]+$ ]] || continue
    tot=$(( r + t ))
    if (( tot >= best_tot )); then
      best_tot=${tot}
      best_iface="${iface}"
    fi
  done </proc/net/dev
  echo "${best_iface}"
}

# Bytes for one iface from /proc/net/dev. Prints: rx tx
read_net_bytes_iface() {
  local want="$1"
  local iface r t
  while read -r line; do
    [[ "${line}" == *":"* ]] || continue
    iface="${line%%:*}"
    iface="${iface#"${iface%%[![:space:]]*}"}"
    iface="${iface%"${iface##*[![:space:]]}"}"
    [[ "${iface}" == "${want}" ]] || continue
    read -r r _ _ _ _ _ _ _ t _ <<<"${line#*:}"
    [[ "${r}" =~ ^[0-9]+$ ]] || continue
    [[ "${t}" =~ ^[0-9]+$ ]] || continue
    echo "${r} ${t}"
    return 0
  done </proc/net/dev
  echo "0 0"
  return 1
}

update_net_dir() {
  local rx_hit=0 tx_hit=0
  if (( NET_RX_BPS >= NET_RX_MIN_BPS )); then rx_hit=1; fi
  if (( NET_TX_BPS >= NET_TX_MIN_BPS )); then tx_hit=1; fi
  if (( rx_hit == 1 && tx_hit == 1 )); then
    NET_DIR="both"
  elif (( rx_hit == 1 )); then
    NET_DIR="rx"
  elif (( tx_hit == 1 )); then
    NET_DIR="tx"
  else
    NET_DIR="none"
  fi
}

# Updates NET_* rate/busy/dir/iface. Store: epoch\tiface\trx\ttx
measure_net_bps() {
  NET_RX_BPS=0
  NET_TX_BPS=0
  NET_BUSY=0
  NET_DISP="off"
  NET_IFACE_RESOLVED="-"
  NET_DIR="none"
  NET_STRIKES=0

  [[ "${NET_CHECK_ENABLED}" == "1" ]] || return 0

  local now rx tx prev_epoch prev_iface prev_rx prev_tx dt drx dtx strikes=0 iface
  now="$(date +%s)"
  iface="$(resolve_net_iface)"
  if [[ -z "${iface}" ]]; then
    NET_DISP="no_iface"
    NET_IFACE_RESOLVED="-"
    return 0
  fi
  NET_IFACE_RESOLVED="${iface}"
  read -r rx tx < <(read_net_bytes_iface "${iface}")

  if [[ ! -f "${NET_PREV_FILE}" ]]; then
    printf '%s\t%s\t%s\t%s\n' "${now}" "${iface}" "${rx}" "${tx}" >"${NET_PREV_FILE}"
    NET_DISP="seed"
    return 0
  fi

  IFS=$'\t' read -r prev_epoch prev_iface prev_rx prev_tx <"${NET_PREV_FILE}" || true
  # Legacy 3-column file (pre-P0): treat as resync
  if [[ -z "${prev_tx:-}" ]] || [[ ! "${prev_rx}" =~ ^[0-9]+$ ]]; then
    printf '%s\t%s\t%s\t%s\n' "${now}" "${iface}" "${rx}" "${tx}" >"${NET_PREV_FILE}"
    NET_DISP="resync"
    clear_net_busy_strikes
    return 0
  fi

  printf '%s\t%s\t%s\t%s\n' "${now}" "${iface}" "${rx}" "${tx}" >"${NET_PREV_FILE}"

  # VPN connect/disconnect: default route iface changed — resync, no false busy
  if [[ "${prev_iface}" != "${iface}" ]]; then
    NET_DISP="resync"
    clear_net_busy_strikes
    log "event: net_iface_changed ${prev_iface} -> ${iface} (counters resynced)"
    return 0
  fi

  dt=$(( now - prev_epoch ))
  if (( dt <= 0 )) || (( dt > LOG_POLL_GAP_WARN_SEC )); then
    NET_DISP="resync"
    clear_net_busy_strikes
    return 0
  fi

  drx=$(( rx - prev_rx ))
  dtx=$(( tx - prev_tx ))
  if (( drx < 0 )); then drx=0; fi
  if (( dtx < 0 )); then dtx=0; fi
  NET_RX_BPS=$(( drx / dt ))
  NET_TX_BPS=$(( dtx / dt ))
  update_net_dir

  local sample_busy=0
  if [[ "${NET_DIR}" != "none" ]]; then
    sample_busy=1
  fi

  if [[ -f "${NET_BUSY_STRIKES_FILE}" ]]; then
    strikes="$(<"${NET_BUSY_STRIKES_FILE}")"
  fi
  if (( sample_busy == 1 )); then
    strikes=$(( strikes + 1 ))
  else
    strikes=0
  fi
  echo "${strikes}" >"${NET_BUSY_STRIKES_FILE}"
  NET_STRIKES="${strikes}"

  if (( strikes >= NET_BUSY_POLLS )); then
    NET_BUSY=1
    NET_DISP="busy"
    if [[ ! -f "${NET_WAS_BUSY_FILE}" ]]; then
      touch "${NET_WAS_BUSY_FILE}"
      log "event: net_busy (if=${iface} dir=${NET_DIR} rx=${NET_RX_BPS}B/s tx=${NET_TX_BPS}B/s rx_min=${NET_RX_MIN_BPS} tx_min=${NET_TX_MIN_BPS} strikes=${strikes}/${NET_BUSY_POLLS})"
    fi
  else
    NET_BUSY=0
    if [[ -f "${NET_WAS_BUSY_FILE}" ]]; then
      rm -f "${NET_WAS_BUSY_FILE}"
      log "event: net_clear (if=${iface} rx=${NET_RX_BPS}B/s tx=${NET_TX_BPS}B/s)"
    fi
    if (( sample_busy == 1 )); then
      NET_DISP="rising/${strikes}"
    else
      NET_DISP="ok"
    fi
  fi
}

net_is_busy() {
  [[ "${NET_BUSY}" == "1" ]]
}

# Instantaneous bulk traffic (grace cancel) — one sample above floor is enough.
net_sample_is_bulk() {
  [[ "${NET_CHECK_ENABLED}" == "1" ]] || return 1
  (( NET_RX_BPS >= NET_RX_MIN_BPS || NET_TX_BPS >= NET_TX_MIN_BPS )) && return 0
  return 1
}
