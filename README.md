# Graceful shutdown (idle + low load)

Powers off your Linux desktop when you are idle and the machine is quiet, after a notification you can cancel.

[Quick start](#quick-start) · [Releases](https://github.com/alkitect/graceful-shutdown/releases) · [License](#license)

Latest release notes: [CHANGELOG.md](CHANGELOG.md) and [GitHub Releases](https://github.com/alkitect/graceful-shutdown/releases). A plain `git clone` follows the default branch tip unless you check out a tag; prefer a tagged release for day-to-day use.

## What this does

Desktops often stay on overnight. Aggressive timers cut power while you are still working; weak ones never fire.

This tool waits until input is idle, then checks that the machine is not doing hard work (CPU/GPU phase gates, bulk network, optional Ubuntu Backup). When those gates pass for long enough, it notifies you, gives a short cancel window, and runs `systemctl poweroff`. Moderate background CPU while you are away can still allow shutdown; long GPU jobs and large downloads keep the machine awake.

Safe by default: poweroff stays off (`POWEROFF_ENABLED=0`). Install and verify first; only enable when you are comfortable with real shutdowns.

## Who this is for

This is for Ubuntu with GNOME Wayland. It uses GNOME's built-in idle signal (Mutter), not a custom X11 hack. You want auto poweroff that will not kill downloads or backups mid-run.

It is not for KDE, X11-only idle setups, or always-on servers.

## Quick start

Install seeds a user timer that periodically runs `idle-low-load-shutdown`, plus config at `~/.config/graceful-shutdown/config`. Leave `POWEROFF_ENABLED=0` until a dry-run checker looks good. The real gate is `POWEROFF_ENABLED` (shipped example uses `DRY_RUN=0`).

Then: [Install](#install) → [Try dry-run](#try-dry-run) → [Enable timer and poweroff](#enable-timer-and-poweroff).

### Install

Needs: GNOME Wayland session with `gdbus`, `systemd --user`, `loginctl`, `ip`, `notify-send`, `flock`, `timeout`, and polkit rights for `systemctl poweroff`.

Stable path: clone or download a release tag from [Releases](https://github.com/alkitect/graceful-shutdown/releases), then run the install script. Tip of the default branch is fine for contributors.

```bash
git clone https://github.com/alkitect/graceful-shutdown.git
cd graceful-shutdown
# optional: git checkout vX.Y.Z   # pin to a release tag
./scripts/install-to-local.sh
```

The binary, timer, and service share the name `idle-low-load-shutdown`. Thresholds and VPN/GPU tuning: see Configure.

### Try dry-run

Confirm the checker and idle path before you enable the timer or real poweroff:

```bash
GS_TOPIC_ROOT="$PWD" ./scripts/verify-graceful-shutdown.sh
DRY_RUN=1 ~/.local/bin/idle-low-load-shutdown
```

Verify should exit cleanly on GNOME Wayland. With `DRY_RUN=1`, the checker logs what it would do without shutting down. Look for `phase=A` or `phase=B` and `load=ok` under moderate background CPU (not stuck `load=high` from a legacy 10% rule). If verify fails on idle, confirm you are on GNOME Wayland and the session looks active as in the script output. While tuning later, watch `~/.local/state/graceful-shutdown/check.log`.

### Enable timer and poweroff

When dry-run looks good, set `POWEROFF_ENABLED=1` in `~/.config/graceful-shutdown/config`, then enable the timer:

```bash
# set POWEROFF_ENABLED=1 in ~/.config/graceful-shutdown/config
./scripts/install-to-local.sh --enable-automation
# or: systemctl --user enable --now idle-low-load-shutdown.timer
```

A plain reinstall restores the timer when any of these hold: the timer was already enabled/active, `~/.config/graceful-shutdown/automation.wanted` exists, or `POWEROFF_ENABLED=1`. That intent file is written on successful enable. You should get a cancelable notification before any real `systemctl poweroff`.

## Check it works

Success is a clean verify and a dry-run checker run with no unexpected poweroff. After enable, you should see checks in `check.log` and a notification you can cancel before shutdown. After an uninstall without purge, a plain reinstall should leave `systemctl --user is-enabled idle-low-load-shutdown.timer` as `enabled` when you had armed the tool.

<details>
<summary>Optional confirmation scripts</summary>

```bash
GS_TOPIC_ROOT="$PWD" ./scripts/verify-graceful-shutdown.sh
DRY_RUN=1 ~/.local/bin/idle-low-load-shutdown
./scripts/test/test-policy-math.sh
./scripts/ci-check.sh
```

</details>

Questions or a stuck install: open a GitHub [Issue](https://github.com/alkitect/graceful-shutdown/issues) or see [CONTRIBUTING.md](CONTRIBUTING.md).

## Support my work

Tip jar for the next desktop fix. Or a coffee so the next script stays boring on purpose.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/alkitect/?hidefeed=true&widget=true&embed=true)

## Uninstall

```bash
./scripts/uninstall-from-local.sh
# also remove config and automation.wanted:
./scripts/uninstall-from-local.sh --purge-config
```

Plain uninstall keeps `config` and `automation.wanted` so a later install can restore the timer. Use `--purge-config` only when you intend to forget that intent.

## Configure

- Dual-GPU ambient noise: raise `GPU_MAX_PCT` or set `GPU_DRM_CARD` to the discrete card.
- VPN: leave `NET_IFACE` empty so the default route (tunnel when connected) is used.
- Phase load: defaults use a critical CPU gate then a short rolling average (see Limits). Tune `CPU_PHASE_*` / `PHASE_*` or set `PHASE_LOAD_ENABLED=0` for the legacy single 10% CPU threshold.
- Thresholds: follow `check.log` / `verify-graceful-shutdown` while away with downloads / backups.

## How it works

Gates run in order: input idle (about 1 min), then an effective ~14 min load streak (clock pauses on hard load, bulk net, or backup), then a grace notification, then `systemctl poweroff` when `POWEROFF_ENABLED=1`. Default load policy is two-phase: first ~10 min only critical CPU/GPU pauses the streak; then a 3 min rolling average confirms the machine is not working hard.

Policy detail: [docs/architecture/](docs/architecture/) · [ADR-001](docs/architecture/ADR-001-graceful-shutdown-policy.md) · [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md).

## Limits & safety

This can power off the machine.

- Platform: GNOME Wayland with Mutter idle only. KDE / X11 idle are unsupported.
- Load: locked or unlocked AFK with moderate background CPU (for example ~40%) can complete the path and power off. Hard CPU (critical threshold), GPU above caps, bulk downloads, and Ubuntu Backup work still pause. Long CPU-only jobs left running while you are away may be powered off after ~15 min plus grace.
- Network: bulk RX/TX on the default-route iface only (VPN-safe; never sums tunnel + wifi).
- Backup: optional Ubuntu Déjà Dup / `duplicity` stay-awake (`BACKUP_CHECK_ENABLED=1`); harmless if those processes never appear.
- Kill-switches: `touch ~/.config/graceful-shutdown/inhibit`, `PHASE_LOAD_ENABLED=0` (legacy strict single-threshold load), `POWEROFF_ENABLED=0`, `systemctl --user stop idle-low-load-shutdown.timer`, or unlock / move the mouse.
- Automation intent: `~/.config/graceful-shutdown/automation.wanted` is written when the timer is enabled. Uninstall keeps it unless `--purge-config`. Reinstall restores the timer when the marker exists, the timer was already enabled, or `POWEROFF_ENABLED=1`.
- Rollback (disarm): `systemctl --user disable --now idle-low-load-shutdown.timer`, remove `automation.wanted`, and set `POWEROFF_ENABLED=0` (config alone can re-arm restore on the next install).
- Defaults: shipped `POWEROFF_ENABLED=0` and `PHASE_LOAD_ENABLED=1`. Prefer a tagged release for day-to-day use; see [Releases](https://github.com/alkitect/graceful-shutdown/releases). A real poweroff soak for v1.0 is a human gate.
- This GitHub repo is the release source for tagged releases and public docs. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).

Optional tip jar: [ko-fi.com/alkitect](https://ko-fi.com/alkitect/?hidefeed=true&widget=true&embed=true)
