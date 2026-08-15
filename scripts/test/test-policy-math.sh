#!/usr/bin/env bash
# Offline policy smoke tests (no poweroff, no systemd). Exit 1 on failure.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

# --- streak pause math (origin shift) ---
streak_start=1000
pause_start=1300
effective=$(( pause_start - streak_start ))
[[ "${effective}" -eq 300 ]] || fail "effective pause elapsed=${effective}"
now=1400
new_start=$(( streak_start + now - pause_start ))
[[ "${new_start}" -eq 1100 ]] || fail "resume origin=${new_start}"
ok "streak pause/resume math"

# --- LOAD_WINDOW_MAX_HIGH ---
max_high=1
[[ 1 -le max_high ]] || fail "1 high should be allowed"
[[ 2 -gt max_high ]] || fail "2 highs should exceed"
ok "LOAD_WINDOW_MAX_HIGH=1"

# --- ceil 95% on N=8 → max 1 ---
n=8
min_ok=95
derived=$(( (n * (100 - min_ok) + 99) / 100 ))
[[ "${derived}" -eq 1 ]] || fail "derived max_high=${derived}"
ok "MIN_OK_FRAC ceil → 1/8"

# --- net dir classification ---
rx_min=204800
tx_min=204800
classify() {
  local rx="$1" tx="$2"
  local rh=0 th=0
  (( rx >= rx_min )) && rh=1
  (( tx >= tx_min )) && th=1
  if (( rh && th )); then echo both
  elif (( rh )); then echo rx
  elif (( th )); then echo tx
  else echo none
  fi
}
[[ "$(classify 300000 1000)" == "rx" ]] || fail "dir rx"
[[ "$(classify 1000 300000)" == "tx" ]] || fail "dir tx"
[[ "$(classify 300000 300000)" == "both" ]] || fail "dir both"
[[ "$(classify 1000 1000)" == "none" ]] || fail "dir none"
ok "net_dir classification"

# --- pause reason ---
reason() {
  local load_b="$1" net_b="$2" backup_b="$3"
  local parts=()
  (( load_b )) && parts+=("load")
  (( net_b )) && parts+=("net")
  (( backup_b )) && parts+=("backup")
  if (( ${#parts[@]} == 0 )); then
    echo -
    return
  fi
  local IFS='+'
  echo "${parts[*]}"
}
[[ "$(reason 1 0 0)" == "load" ]] || fail "reason load"
[[ "$(reason 0 1 0)" == "net" ]] || fail "reason net"
[[ "$(reason 0 0 1)" == "backup" ]] || fail "reason backup"
[[ "$(reason 1 1 0)" == "load+net" ]] || fail "reason load+net"
[[ "$(reason 1 0 1)" == "load+backup" ]] || fail "reason load+backup"
[[ "$(reason 0 1 1)" == "net+backup" ]] || fail "reason net+backup"
[[ "$(reason 1 1 1)" == "load+net+backup" ]] || fail "reason load+net+backup"
[[ "$(reason 0 0 0)" == "-" ]] || fail "reason none"
ok "pause reason"

# --- set -e + missing streak file (regression 2026-07-14) ---
# `[[ -f ]] && cat` returns 1 when missing; "$(…)" then aborted the checker.
bash -c '
set -euo pipefail
streak_start_epoch() {
  if [[ -f /nonexistent-streak-file ]]; then
    cat /nonexistent-streak-file
  fi
}
streak_start="$(streak_start_epoch)"
[[ -z "${streak_start}" ]]
' || fail "streak_start_epoch must return 0 when file missing under set -e"
ok "streak_start_epoch missing-file under set -e"

# --- backup busy: unit/duplicity vs UI-only ---
backup_busy() {
  local unit="$1" dup="$2" ui="$3" treat_ui="$4"
  local busy=0
  (( unit == 1 || dup == 1 )) && busy=1
  if (( treat_ui == 1 && ui == 1 )); then
    busy=1
  fi
  echo "${busy}"
}
[[ "$(backup_busy 0 0 1 0)" == "0" ]] || fail "UI-only must not busy when TREAT_UI=0"
[[ "$(backup_busy 0 0 1 1)" == "1" ]] || fail "UI-only busy when TREAT_UI=1"
[[ "$(backup_busy 0 1 0 0)" == "1" ]] || fail "duplicity busy"
[[ "$(backup_busy 1 0 0 0)" == "1" ]] || fail "unit busy"
[[ "$(backup_busy 0 0 0 0)" == "0" ]] || fail "idle ok"
ok "backup busy classification"

# --- default-route helper (read-only; skip if no ip) ---
if command -v ip >/dev/null 2>&1; then
  iface="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' || true)"
  if [[ -n "${iface}" && "${iface}" != "lo" ]]; then
    ok "default-route iface=${iface}"
  else
    echo "WARN: no default-route iface (offline?)"
  fi
fi

echo "ALL_POLICY_SMOKE_OK"
