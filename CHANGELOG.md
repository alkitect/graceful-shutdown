# Changelog

## Unreleased

## 0.3.2 — 2026-08-15

- CI: pin `XDG_CONFIG_HOME` / `XDG_STATE_HOME` under tmp `HOME` so install/uninstall assertions pass on GitHub Actions.

## 0.3.1 — 2026-08-15

- Initial public extract from private Linux customization topic.
- Variant A layout: `scripts/lib/{idle,load,net,backup}.sh`, `scripts/test/test-policy-math.sh`.
- Install deploys libs to `~/.local/bin/graceful-shutdown-lib/`; uninstall removes verify + libs.
- Lib-aware verify (`GS_TOPIC_ROOT` / repo resolve; FAIL if installed without root).
- `CHECKER_VERSION=gs-lib-1` (structure peel; policy behavior unchanged from pre-extract topic).
- CI: `bash -n`, policy math, `ci-check.sh` (forbidden refs, safety defaults, install/uninstall round-trip).
