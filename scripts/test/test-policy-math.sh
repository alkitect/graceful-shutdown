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

# --- two-phase load eval (source load.sh with stubs) ---
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPDIR_PHASE="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_PHASE}"' EXIT

PHASE_LOAD_ENABLED=1
PHASE_A_SEC=600
CPU_PHASE_A_MAX_PCT=65
PHASE_B_WINDOW_SEC=180
CPU_PHASE_B_MAX_PCT=50
GPU_PHASE_B_MAX_PCT=20
CPU_PHASE_B_SPIKE_MAX_PCT=80
PHASE_B_MIN_SAMPLES=5
GPU_MAX_PCT=15
GPU_CHECK_VRAM=0
GPU_VRAM_MAX_PCT=90
CPU_MAX_PCT=10
CPU_IDLE_PCT=7
GPU_IDLE_PCT=10
HYSTERESIS_OK_POLLS=2
LOAD_WINDOW_ENABLED=0
LOAD_WINDOW_FILE="${TMPDIR_PHASE}/load-window.tsv"
LOAD_WINDOW_POLLS=8
LOAD_WINDOW_REQUIRE_FULL=1
LOAD_WINDOW_METRIC=avg
LOAD_WINDOW_MAX_HIGH=1
LOAD_WINDOW_MIN_OK_FRAC=95
HYSTERESIS_STATE_FILE="${TMPDIR_PHASE}/hyst.state"
HYSTERESIS_OK_COUNT_FILE="${TMPDIR_PHASE}/hyst.count"
CPU_SAMPLE_SEC=0
EXT_CMD_TIMEOUT_SEC=1
log() { :; }
run_timeout() { "$@"; }

# shellcheck source=scripts/lib/load.sh
source "${ROOT}/scripts/lib/load.sh"

# Phase A: 40% OK, 70% busy
EFFECTIVE_STREAK_SEC=100
CPU_PCT_RESULT=40
GPU_PCT_RESULT=0
GPU_VRAM_PCT_RESULT=0
load_phase_eval && fail "phase A 40% should not be busy" || true
CPU_PCT_RESULT=70
load_phase_eval || fail "phase A 70% should be busy"
ok "phase A critical threshold"

# Phase B: build 5 samples @ 40% then eval
EFFECTIVE_STREAK_SEC=700
: >"${LOAD_WINDOW_FILE}"
now="$(date +%s)"
for i in 1 2 3 4 5; do
  printf '%s\t40\t0\t0\t0\n' "$(( now - 30 * i ))" >>"${LOAD_WINDOW_FILE}"
done
CPU_PCT_RESULT=40
load_phase_eval && fail "phase B avg 40% should not be busy" || true
# avg 55%
: >"${LOAD_WINDOW_FILE}"
for i in 1 2 3 4 5; do
  printf '%s\t55\t0\t0\t0\n' "$(( now - 30 * i ))" >>"${LOAD_WINDOW_FILE}"
done
CPU_PCT_RESULT=45
load_phase_eval || fail "phase B avg 55% should be busy"
ok "phase B rolling avg"

# Spike in window
: >"${LOAD_WINDOW_FILE}"
for i in 1 2 3 4; do
  printf '%s\t40\t0\t0\t0\n' "$(( now - 30 * i ))" >>"${LOAD_WINDOW_FILE}"
done
printf '%s\t85\t0\t0\t1\n' "$(( now - 10 ))" >>"${LOAD_WINDOW_FILE}"
CPU_PCT_RESULT=40
load_phase_eval || fail "phase B spike 85% should be busy"
ok "phase B spike"

# Grace critical: 40% OK, sample fail busy, 70% busy
CPU_PCT_RESULT=40
GPU_PCT_RESULT=0
load_phase_critical_busy && fail "grace 40% should not abort" || true
CPU_PCT_RESULT="-"
load_phase_critical_busy || fail "grace sample fail should abort"
CPU_PCT_RESULT=70
GPU_PCT_RESULT=0
load_phase_critical_busy || fail "grace 70% should abort"
ok "grace instant critical"

# GPU instant in phase A
EFFECTIVE_STREAK_SEC=100
CPU_PCT_RESULT=10
GPU_PCT_RESULT=40
load_phase_eval || fail "GPU 40% should be busy"
ok "GPU instant block"

# Legacy mode still uses CPU_MAX
PHASE_LOAD_ENABLED=0
CPU_PCT_RESULT=40
GPU_PCT_RESULT=0
load_is_high || fail "legacy 40% > CPU_MAX 10 should be high"
PHASE_LOAD_ENABLED=1
ok "legacy load_is_high"

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
