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

if grep -qF "${_p1}${_p2}" scripts/verify-graceful-shutdown.sh; then
  echo "ci-check: verify still references ${_p1}${_p2}" >&2
  exit 1
fi

grep -q 'CHECKER_VERSION=gs-lib-1' scripts/idle-low-load-shutdown.sh
grep -qE '^POWEROFF_ENABLED=0' config/example.config
grep -qE '^DRY_RUN=0' config/example.config

find scripts -type f -name '*.sh' -print0 | xargs -0 -r bash -n
./scripts/test/test-policy-math.sh

tmp="$(mktemp -d)"
cleanup() { rm -rf "${tmp}"; }
trap cleanup EXIT
export HOME="${tmp}"
export XDG_CONFIG_HOME="${tmp}/.config"
export XDG_STATE_HOME="${tmp}/.local/state"
"${ROOT}/scripts/install-to-local.sh"
test -x "${tmp}/.local/bin/idle-low-load-shutdown"
test -x "${tmp}/.local/bin/verify-graceful-shutdown"
grep -q 'CHECKER_VERSION=gs-lib-1' "${tmp}/.local/bin/idle-low-load-shutdown"
for lib in idle.sh load.sh net.sh backup.sh; do
  test -f "${tmp}/.local/bin/graceful-shutdown-lib/${lib}"
done
test -f "${tmp}/.config/graceful-shutdown/config" \
  || { echo "ci-check: config not under tmp HOME (XDG isolation broken?)" >&2; exit 1; }

"${ROOT}/scripts/uninstall-from-local.sh"
test ! -e "${tmp}/.local/bin/idle-low-load-shutdown"
test ! -e "${tmp}/.local/bin/verify-graceful-shutdown"
test ! -e "${tmp}/.local/bin/graceful-shutdown-lib"
test -f "${tmp}/.config/graceful-shutdown/config"

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
if grep -rE '/home/alex' --include='*.md' . --exclude-dir=.git >/dev/null 2>&1; then
  echo "ci-check: public markdown must not contain /home/alex host paths" >&2
  grep -rE '/home/alex' --include='*.md' . --exclude-dir=.git >&2 || true
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
