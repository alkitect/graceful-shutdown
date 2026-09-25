#!/usr/bin/env bash
# Release gate for graceful-shutdown (local + CI).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# Patterns encoded so this file is not a false positive.
_p1='Python/'
_p2='Linux'
_p3='.cursor/plans'
_p4='topics/graceful-shutdown'
_p5='Proton'
_p6='9070'
_p7='proton0'
FORBIDDEN_RE="${_p1}${_p2}|${_p3}|${_p4}|${_p5}|${_p6}|${_p7}"

hits="$(grep -rE "${FORBIDDEN_RE}" \
  --include='*.sh' --include='*.md' --include='*.config' --include='*.example' . \
  --exclude-dir=.git --exclude-dir=__pycache__ \
  --exclude='ci-check.sh' 2>/dev/null || true)"
if [[ -n "${hits}" ]]; then
  echo "ci-check: forbidden path refs found:" >&2
  echo "${hits}" >&2
  exit 1
fi

# Required public README H2s (anchored; canonical list for this repo)
REQUIRED_H2=(
  "## What this does"
  "## Who this is for"
  "## Quick start"
  "## Check it works"
  "## Uninstall"
  "## Limits & safety"
  "## License"
)
for h in "${REQUIRED_H2[@]}"; do
  grep -qFx "${h}" README.md || { echo "ci-check: README missing H2: ${h}" >&2; exit 1; }
done
if grep -qE '\bSSOT\b' README.md; then
  echo "ci-check: README must not use SSOT; say release source" >&2
  exit 1
fi

# Tip jar: FUNDING.yml + Ko-fi GitHub button (alkitect)
[[ -f .github/FUNDING.yml ]] || { echo "ci-check: missing .github/FUNDING.yml" >&2; exit 1; }
grep -qE '^[[:space:]]*ko_fi:[[:space:]]*alkitect[[:space:]]*$' .github/FUNDING.yml \
  || { echo "ci-check: .github/FUNDING.yml must set ko_fi: alkitect" >&2; exit 1; }
grep -qF 'ko-fi.com/alkitect' README.md \
  || { echo "ci-check: README must include Ko-fi tip link ko-fi.com/alkitect" >&2; exit 1; }
grep -qF 'ko-fi.com/img/githubbutton_sm.svg' README.md \
  || { echo "ci-check: README must include Ko-fi GitHub button (githubbutton_sm.svg)" >&2; exit 1; }
if grep -qiE 'patreon\.com|buymeacoffee\.com' README.md; then
  echo "ci-check: README must not link Patreon or Buy Me a Coffee" >&2
  exit 1
fi

if grep -qF "${_p1}${_p2}" scripts/verify-graceful-shutdown.sh; then
  echo "ci-check: verify still references ${_p1}${_p2}" >&2
  exit 1
fi

grep -q 'CHECKER_VERSION=gs-lib-2' scripts/idle-low-load-shutdown.sh
grep -qE '^POWEROFF_ENABLED=0' config/example.config
grep -qE '^DRY_RUN=0' config/example.config
grep -qE '^PHASE_LOAD_ENABLED=1' config/example.config
for key in PHASE_A_SEC CPU_PHASE_A_MAX_PCT PHASE_B_WINDOW_SEC CPU_PHASE_B_MAX_PCT GPU_PHASE_B_MAX_PCT CPU_PHASE_B_SPIKE_MAX_PCT; do
  grep -qE "^${key}=" config/example.config \
    || { echo "ci-check: example.config missing ${key}" >&2; exit 1; }
done

find scripts -type f -name '*.sh' -print0 | xargs -0 -r bash -n
./scripts/test/test-policy-math.sh

# Em-dash / en-dash ban in README (public product voice)
if LC_ALL=C grep -q $'\xe2\x80\x93\|\xe2\x80\x94' README.md; then
  echo "ci-check: README must not use en-dash or em-dash" >&2
  exit 1
fi

# Vendor sync when running inside Linux monorepo checkout
_canon=""
if [[ -f "${ROOT}/../../shared/lib/automation-wanted.sh" ]]; then
  _canon="$(cd "${ROOT}/../.." && pwd)/shared/lib/automation-wanted.sh"
elif [[ -n "${CANONICAL:-}" && -f "${CANONICAL}" ]]; then
  _canon="${CANONICAL}"
fi
if [[ -n "${_canon}" ]]; then
  cmp -s "${_canon}" "${ROOT}/scripts/lib/automation-wanted.sh" \
    || { echo "ci-check: scripts/lib/automation-wanted.sh drifts from ${_canon}" >&2; exit 1; }
fi
test -f "${ROOT}/scripts/lib/automation-wanted.sh"

tmp="$(mktemp -d)"
cleanup() { rm -rf "${tmp}"; }
trap cleanup EXIT
export HOME="${tmp}"
export XDG_CONFIG_HOME="${tmp}/.config"
export XDG_STATE_HOME="${tmp}/.local/state"
export XDG_RUNTIME_DIR="${tmp}/run"
mkdir -p "${XDG_CONFIG_HOME}" "${XDG_STATE_HOME}" "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"
export ALKITECT_CI_TMP=1

# shellcheck source=scripts/lib/automation-wanted.sh
source "${ROOT}/scripts/lib/automation-wanted.sh"
_cfg="${XDG_CONFIG_HOME}/graceful-shutdown"

_unit_snap() {
  {
    echo "=== idle-low-load-shutdown.timer ==="
    systemctl --user is-enabled idle-low-load-shutdown.timer 2>/dev/null || echo "is-enabled:n/a"
    systemctl --user show idle-low-load-shutdown.timer -p ActiveState,UnitFileState,SubState --no-page 2>/dev/null \
      || echo "show:n/a"
  } >"$1"
}
_snap_b="$(mktemp)"; _snap_a="$(mktemp)"
_unit_snap "${_snap_b}"

"${ROOT}/scripts/install-to-local.sh"
test -x "${tmp}/.local/bin/idle-low-load-shutdown"
test -x "${tmp}/.local/bin/verify-graceful-shutdown"
grep -q 'CHECKER_VERSION=gs-lib-2' "${tmp}/.local/bin/idle-low-load-shutdown"
for lib in idle.sh load.sh net.sh backup.sh; do
  test -f "${tmp}/.local/bin/graceful-shutdown-lib/${lib}"
done
test ! -e "${tmp}/.local/bin/graceful-shutdown-lib/automation-wanted.sh" \
  || { echo "ci-check: automation-wanted must not install into graceful-shutdown-lib" >&2; exit 1; }
test -f "${tmp}/.config/graceful-shutdown/config" \
  || { echo "ci-check: config not under tmp HOME (XDG isolation broken?)" >&2; exit 1; }
for key in PHASE_LOAD_ENABLED PHASE_A_SEC CPU_PHASE_A_MAX_PCT PHASE_B_WINDOW_SEC CPU_PHASE_B_MAX_PCT GPU_PHASE_B_MAX_PCT CPU_PHASE_B_SPIKE_MAX_PCT; do
  grep -qE "^[[:space:]]*${key}=" "${tmp}/.config/graceful-shutdown/config" \
    || { echo "ci-check: fresh seed missing ${key}" >&2; exit 1; }
done
# Fresh seed: POWEROFF=0, no marker → restore should not arm
test ! -f "${_cfg}/automation.wanted" \
  || { echo "ci-check: fresh install must not write automation.wanted" >&2; exit 1; }

# Merge PHASE keys into a legacy config that lacks them
cat >"${_cfg}/config" <<'EOF'
POWEROFF_ENABLED=0
INPUT_IDLE_SEC=60
LOW_LOAD_STREAK_SEC=840
CPU_MAX_PCT=10
GPU_MAX_PCT=15
DRY_RUN=0
EOF
"${ROOT}/scripts/install-to-local.sh"
for key in PHASE_LOAD_ENABLED PHASE_A_SEC CPU_PHASE_A_MAX_PCT PHASE_B_WINDOW_SEC CPU_PHASE_B_MAX_PCT GPU_PHASE_B_MAX_PCT CPU_PHASE_B_SPIKE_MAX_PCT; do
  grep -qE "^[[:space:]]*${key}=" "${_cfg}/config" \
    || { echo "ci-check: merge into legacy config missing ${key}" >&2; exit 1; }
done
grep -qE '^[[:space:]]*PHASE_LOAD_ENABLED=1' "${_cfg}/config" \
  || { echo "ci-check: merge must set PHASE_LOAD_ENABLED=1 from example" >&2; exit 1; }

# Marker survives uninstall; purge removes it
aw_mark_wanted "${_cfg}"
"${ROOT}/scripts/uninstall-from-local.sh"
test -f "${_cfg}/automation.wanted" \
  || { echo "ci-check: uninstall must keep automation.wanted" >&2; exit 1; }
test -f "${_cfg}/config"

"${ROOT}/scripts/install-to-local.sh"
# Marker + CI_TMP path should re-mark (restore decision true)
test -f "${_cfg}/automation.wanted" \
  || { echo "ci-check: reinstall with marker must keep/write automation.wanted" >&2; exit 1; }

"${ROOT}/scripts/uninstall-from-local.sh" --purge-config
test ! -e "${_cfg}/automation.wanted" \
  || { echo "ci-check: --purge-config must remove automation.wanted" >&2; exit 1; }
test ! -e "${_cfg}/config"

# POWEROFF_ENABLED=1 alone arms restore (re-seed config)
"${ROOT}/scripts/install-to-local.sh"
sed -i 's/^POWEROFF_ENABLED=.*/POWEROFF_ENABLED=1/' "${_cfg}/config"
rm -f "${_cfg}/automation.wanted"
"${ROOT}/scripts/install-to-local.sh"
test -f "${_cfg}/automation.wanted" \
  || { echo "ci-check: POWEROFF_ENABLED=1 must arm restore (write marker under CI_TMP)" >&2; exit 1; }

"${ROOT}/scripts/uninstall-from-local.sh" --purge-config
test ! -e "${tmp}/.local/bin/idle-low-load-shutdown"
test ! -e "${tmp}/.local/bin/verify-graceful-shutdown"
test ! -e "${tmp}/.local/bin/graceful-shutdown-lib"

_unit_snap "${_snap_a}"
if ! diff -q "${_snap_b}" "${_snap_a}" >/dev/null; then
  echo "ci-check: live idle-low-load-shutdown.timer state changed during CI_TMP install/uninstall:" >&2
  diff -u "${_snap_b}" "${_snap_a}" >&2 || true
  exit 1
fi
rm -f "${_snap_b}" "${_snap_a}"

# Versioning gate (alkitect public extracts)
if [[ -f docs/PUBLISH.md ]] && grep -qF 'RC-BEFORE-1.0' docs/PUBLISH.md; then
  :
else
  if [[ -f CHANGELOG.md ]] && grep -qE '^## 0\.9\.0' CHANGELOG.md; then
    echo "ci-check: CHANGELOG ## 0.9.0 is not the default first tag; add RC-BEFORE-1.0 to docs/PUBLISH.md or use 0.1.0+" >&2
    exit 1
  fi
  for _vf in docs/PUBLISH.md README.md; do
    if [[ -f "${_vf}" ]] && grep -qE 'v0\.9\.0' "${_vf}"; then
      echo "ci-check: ${_vf} mentions v0.9.0 without RC-BEFORE-1.0" >&2
      exit 1
    fi
  done
fi
if grep -rE '/home/[A-Za-z0-9._-]+' --include='*.md' . \
  --exclude-dir=.git --exclude='ci-check.sh' >/dev/null 2>&1; then
  echo "ci-check: public markdown must not contain /home/<user> host paths" >&2
  grep -rE '/home/[A-Za-z0-9._-]+' --include='*.md' . \
    --exclude-dir=.git --exclude='ci-check.sh' >&2 || true
  exit 1
fi
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && git describe --tags --abbrev=0 >/dev/null 2>&1; then
  _tag="$(git describe --tags --abbrev=0)"
  _tag="${_tag#v}"
  _first="$(awk '/^## [0-9]+\.[0-9]+\.[0-9]+/{ sub(/^## /,""); sub(/ .*/,""); print; exit }' CHANGELOG.md)"
  if [[ -n "${_first}" && "${_first}" != "${_tag}" ]]; then
    echo "ci-check: CHANGELOG first dated section ${_first} != git describe ${_tag}" >&2
    exit 1
  fi
fi

echo "ci-check: OK"
