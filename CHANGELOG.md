# Changelog

## Unreleased

## 0.3.5 — 2026-09-14

- Install: restore timer from `automation.wanted` marker and/or `POWEROFF_ENABLED=1` (not only prior enablement snapshot). Uninstall keeps the marker unless `--purge-config`.
- Helper: vendored `scripts/lib/automation-wanted.sh`; ci-check covers marker/purge/POWEROFF matrix and README em-dash ban.
- Docs: Quick start / Limits document restore triggers and rollback triad.

## 0.3.4 — 2026-09-14

- Docs: portal README (Try dry-run before enable, Issues help, Releases surface).
- Install: restore `idle-low-load-shutdown.timer` when it was already enabled/active; warn if `POWEROFF_ENABLED=1` but the timer is disabled. Uninstall prints that live polling stops.
- Tip catch-up: CI tmp systemctl skip, Ko-fi Support section, path scrub.

## 0.3.3 — 2026-08-15
- CI: bump `actions/checkout` to v5 (Node 24; silences Node 20 deprecation warning).

## 0.3.2 — 2026-08-15

- CI: pin `XDG_CONFIG_HOME` / `XDG_STATE_HOME` under tmp `HOME` so install/uninstall assertions pass on GitHub Actions.

## 0.3.1 — 2026-08-15

- Initial public extract from private Linux customization topic.
- Variant A layout: `scripts/lib/{idle,load,net,backup}.sh`, `scripts/test/test-policy-math.sh`.
- Install deploys libs to `~/.local/bin/graceful-shutdown-lib/`; uninstall removes verify + libs.
- Lib-aware verify (`GS_TOPIC_ROOT` / repo resolve; FAIL if installed without root).
- `CHECKER_VERSION=gs-lib-1` (structure peel; policy behavior unchanged from pre-extract topic).
- CI: `bash -n`, policy math, `ci-check.sh` (forbidden refs, safety defaults, install/uninstall round-trip).
