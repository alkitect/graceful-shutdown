# Contributing

## README conventions

Public README required H2s (exact strings; enforced by `./scripts/ci-check.sh`):

```text
## What this does
## Who this is for
## Quick start
## Check it works
## Uninstall
## Limits & safety
## License
```

Put the beginner path (install / verify / uninstall) above limits. Do not put private monorepo paths or the token `SSOT` in README prose — say “release source” instead.

Also enforced by `./scripts/ci-check.sh`:

- `.github/FUNDING.yml` with `ko_fi: alkitect`
- README Ko-fi GitHub button (`githubbutton_sm.svg` → `ko-fi.com/alkitect`) under the tagline
- README soft tip containing `ko-fi.com/alkitect` (after License)
- README must not link Patreon or Buy Me a Coffee

Gate: `./scripts/ci-check.sh`.

## Versioning

First public tag is recorded in `docs/PUBLISH.md` (`First public tag:`). Default is **0.1.0**. Never copy another alkitect repo’s tag. Use `RC-BEFORE-1.0` in PUBLISH only for an intentional 0.9.x RC. After the first tag, bump from CHANGELOG Unreleased (`feat` → minor, `fix` → patch). Maintainers: `./scripts/ci-check.sh` must pass before tag.

## Bug reports

Please include:

- Distro and desktop (expect GNOME Wayland)
- Whether Mutter `GetIdletime` works (`gdbus` call in verify output)
- Relevant `~/.local/state/graceful-shutdown/check.log` / `journalctl --user -t graceful-shutdown` lines (redact hostnames; logs may contain traffic rates)
- Config thresholds (not secrets)

## Behavior changes

If you change policy semantics, update:

- [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md)
- [docs/architecture/ADR-001-graceful-shutdown-policy.md](docs/architecture/ADR-001-graceful-shutdown-policy.md)

Run before PR:

```bash
find scripts -type f -name '*.sh' -print0 | xargs -0 -r bash -n
./scripts/test/test-policy-math.sh
./scripts/ci-check.sh
```

## Sync policy (dual maintenance)

- **Release source:** this GitHub repository (tagged releases, public docs, ADR-001).
- **Daily driver:** a private Linux customization tree may develop first; before the next public tag, copy behavior changes into this repo:
  - `scripts/**`
  - `config/example.config`
  - `docs/IMPLEMENTATION.md`
  - `docs/architecture/ADR-001*.md`
- After a public tag, optionally mirror those paths back into the private tree if it lagged.
- **Never** sync private Cursor plans, machine journals, or host-specific calibration values into this repo.
- **Conflicts:** a human maintainer chooses; no automatic overwrite.
- Private monorepo ADR copies are **mirrors** with a banner pointing here; semantic edits land in this repo first.

## Safety defaults

Shipped `example.config` keeps `POWEROFF_ENABLED=0` and `DRY_RUN=0`. Primary safety is `POWEROFF_ENABLED`; use `DRY_RUN=1` only for temporary soak logging. Do not flip `POWEROFF_ENABLED=1` in the example without a version bump and clear README warning.
