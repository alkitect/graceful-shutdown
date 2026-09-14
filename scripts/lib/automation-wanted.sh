#!/usr/bin/env bash
# Intent marker + systemd user-unit restore helpers for host automation.
# Canonical (Linux monorepo): shared/lib/automation-wanted.sh
# Public extracts vendor an identical copy at scripts/lib/automation-wanted.sh
# Keep copies byte-identical (scripts/verify-vendored-automation-wanted.sh).
#
# Call aw_snapshot_units at install START (before overwriting units / daemon-reload).
# Uninstall keeps automation.wanted unless --purge-config.

# shellcheck shell=bash

aw_marker_path() {
  local cfg_dir="${1:?cfg_dir}"
  printf '%s\n' "${cfg_dir%/}/automation.wanted"
}

aw_mark_wanted() {
  local cfg_dir="${1:?cfg_dir}"
  local marker
  marker="$(aw_marker_path "${cfg_dir}")"
  mkdir -p "${cfg_dir}"
  # One-line timestamp for humans; presence is the contract.
  date -Is >"${marker}" 2>/dev/null || date >"${marker}"
}

aw_is_wanted() {
  local cfg_dir="${1:?cfg_dir}"
  [[ -f "$(aw_marker_path "${cfg_dir}")" ]]
}

# Snapshot is-enabled / is-active for listed units into globals:
#   AW_SNAPSHOT_ENABLED=1|0  AW_SNAPSHOT_ACTIVE=1|0
# Sets either flag if ANY listed unit matches.
aw_snapshot_units() {
  AW_SNAPSHOT_ENABLED=0
  AW_SNAPSHOT_ACTIVE=0
  if [[ -n "${ALKITECT_CI_TMP:-}" ]]; then
    return 0
  fi
  command -v systemctl >/dev/null 2>&1 || return 0
  local u
  for u in "$@"; do
    if systemctl --user is-enabled "${u}" >/dev/null 2>&1; then
      AW_SNAPSHOT_ENABLED=1
    fi
    if systemctl --user is-active "${u}" >/dev/null 2>&1; then
      AW_SNAPSHOT_ACTIVE=1
    fi
  done
}

# Returns 0 if restore should run.
# Args: cfg_dir, then optional extra "armed" predicates already evaluated by caller
# via AW_ARMED_CONFIG=1 (e.g. POWEROFF_ENABLED=1).
aw_should_restore() {
  local cfg_dir="${1:?cfg_dir}"
  if [[ "${AW_FORCE_ENABLE:-0}" == "1" ]]; then
    return 0
  fi
  if [[ "${AW_SNAPSHOT_ENABLED:-0}" == "1" || "${AW_SNAPSHOT_ACTIVE:-0}" == "1" ]]; then
    return 0
  fi
  if aw_is_wanted "${cfg_dir}"; then
    return 0
  fi
  if [[ "${AW_ARMED_CONFIG:-0}" == "1" ]]; then
    return 0
  fi
  return 1
}

# enable --now listed units; no-op under ALKITECT_CI_TMP.
# Usage: aw_enable_units <why> <unit> [unit...]
aw_enable_units() {
  local why="${1:?why}"
  shift
  if [[ -n "${ALKITECT_CI_TMP:-}" ]]; then
    echo "ALKITECT_CI_TMP=1: skipped enable (${why}): $*"
    return 0
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not found; cannot enable: $*" >&2
    return 1
  fi
  echo "Enabling units (${why}): $*"
  systemctl --user enable --now "$@"
}
