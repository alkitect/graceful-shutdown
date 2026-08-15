#!/usr/bin/env bash
# Ubuntu Backup / Déjà Dup helpers (sourced by idle-low-load-shutdown; functions only).
# Depends on main: log, BACKUP_* globals
measure_backup_busy() {
  BACKUP_BUSY=0
  BACKUP_DISP="off"

  [[ "${BACKUP_CHECK_ENABLED}" == "1" ]] || return 0

  local unit_active=0 proc_dup=0 proc_ui=0 sample_busy=0 how="" cmdline

  if command -v systemctl >/dev/null 2>&1; then
    if [[ "$(systemctl --user is-active deja-dup.service 2>/dev/null || true)" == "active" ]]; then
      unit_active=1
    fi
  fi
  if command -v pgrep >/dev/null 2>&1; then
    if pgrep -x duplicity >/dev/null 2>&1; then
      proc_dup=1
    fi
    while read -r cmdline; do
      [[ -z "${cmdline}" ]] && continue
      if [[ "${cmdline}" == *"--gapplication-service"* ]]; then
        continue
      fi
      proc_ui=1
      break
    done < <(pgrep -x deja-dup -a 2>/dev/null | sed 's/^[0-9][0-9]*[[:space:]]*//' || true)
  fi

  sample_busy=0
  (( unit_active == 1 || proc_dup == 1 )) && sample_busy=1
  if [[ "${BACKUP_TREAT_UI_PROCESS}" == "1" ]] && (( proc_ui == 1 )); then
    sample_busy=1
  fi

  if (( sample_busy == 1 )); then
    BACKUP_BUSY=1
    how=""
    (( unit_active == 1 )) && how+="unit"
    if (( proc_dup == 1 )); then
      [[ -n "${how}" ]] && how+="+"
      how+="duplicity"
    fi
    if [[ "${BACKUP_TREAT_UI_PROCESS}" == "1" ]] && (( proc_ui == 1 )); then
      [[ -n "${how}" ]] && how+="+"
      how+="deja-dup"
    elif (( proc_ui == 1 )); then
      [[ -n "${how}" ]] && how+="+ui"
    fi
    [[ -z "${how}" ]] && how="unknown"
    BACKUP_DISP="busy/${how}"
    rm -f "${BACKUP_UI_PENDING_FILE}"
    if [[ ! -f "${BACKUP_WAS_BUSY_FILE}" ]]; then
      touch "${BACKUP_WAS_BUSY_FILE}"
      log "event: backup_busy (${how})"
    fi
  else
    BACKUP_BUSY=0
    if (( proc_ui == 1 )); then
      BACKUP_DISP="ok/ui_pending"
      if [[ ! -f "${BACKUP_UI_PENDING_FILE}" ]]; then
        touch "${BACKUP_UI_PENDING_FILE}"
        log "event: backup_ui_pending (deja-dup UI alive; unit/duplicity idle — not blocking)"
      fi
    else
      BACKUP_DISP="ok"
      if [[ -f "${BACKUP_UI_PENDING_FILE}" ]]; then
        rm -f "${BACKUP_UI_PENDING_FILE}"
        log "event: backup_ui_clear"
      fi
    fi
    if [[ -f "${BACKUP_WAS_BUSY_FILE}" ]]; then
      rm -f "${BACKUP_WAS_BUSY_FILE}"
      log "event: backup_clear"
    fi
  fi
}

backup_is_busy() {
  [[ "${BACKUP_BUSY}" == "1" ]]
}
