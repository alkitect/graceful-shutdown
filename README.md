# Graceful shutdown (idle + low load)

Powers off your Linux desktop when you’re idle and the machine is quiet — after a notification you can cancel.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/alkitect/?hidefeed=true&widget=true&embed=true)

## What this does

Desktops often stay on overnight. Aggressive timers cut power while you’re still working; weak ones never fire.

This tool waits until **input is idle**, then checks that **CPU/GPU and network stay calm** (and optionally that Ubuntu Backup isn’t running). When those gates pass for long enough, it **notifies you**, gives a short cancel window, and runs `systemctl poweroff`.

**Safe by default:** poweroff stays off (`POWEROFF_ENABLED=0`). Install and verify first; only enable when you’re comfortable with real shutdowns.

## Who this is for

- **In:** Ubuntu + **GNOME Wayland** — uses GNOME’s built-in idle signal (Mutter), not a custom X11 hack.
- **In:** You want auto poweroff that **won’t kill downloads or backups** mid-run.
- **Not for:** KDE, X11-only idle setups, or always-on servers.

## Quick start

```bash
git clone https://github.com/alkitect/graceful-shutdown.git
cd graceful-shutdown
./scripts/install-to-local.sh
systemctl --user enable --now idle-low-load-shutdown.timer
```

**What you installed:** a user timer that periodically runs `idle-low-load-shutdown`. Config is seeded at `~/.config/graceful-shutdown/config`. The binary, timer, and service share that name.

**Stay safe before enabling poweroff:** leave `POWEROFF_ENABLED=0` until verify looks good. Optional: set `DRY_RUN=1` temporarily so checks log without shutting down (shipped example uses `DRY_RUN=0`; the real gate is `POWEROFF_ENABLED`). When ready, set `POWEROFF_ENABLED=1`, or use `./scripts/install-to-local.sh --enable-automation`. Thresholds and VPN/GPU tuning: see **Configure**.

**Needs:** GNOME Wayland session with `gdbus`, `systemd --user`, `loginctl`, `ip`, `notify-send`, `flock`, `timeout`, and polkit rights for `systemctl poweroff`.

## Check it works

You want a clean verify and a dry-run checker run with no unexpected poweroff.

```bash
GS_TOPIC_ROOT="$PWD" ./scripts/verify-graceful-shutdown.sh
DRY_RUN=1 ~/.local/bin/idle-low-load-shutdown
```

- If verify fails on idle: confirm you’re on GNOME Wayland and the session looks active as in the script output.
- While tuning later: watch `~/.local/state/graceful-shutdown/check.log`.

Maintainers: `./scripts/test/test-policy-math.sh` · `./scripts/ci-check.sh`.

## Uninstall

```bash
./scripts/uninstall-from-local.sh
# also remove config:
./scripts/uninstall-from-local.sh --purge-config
```

## Configure

- Dual-GPU ambient noise: raise `GPU_MAX_PCT` or set `GPU_DRM_CARD` to the discrete card.
- VPN: leave `NET_IFACE` empty so the default route (tunnel when connected) is used.
- Thresholds: follow `check.log` / `verify-graceful-shutdown` while away with downloads / backups.

## How it works

Gates: input idle → effective low-load streak (pause clock on busy load/net/backup) → grace → `systemctl poweroff`.

| Path | Role |
|------|------|
| `scripts/idle-low-load-shutdown.sh` | Checker (`CHECKER_VERSION=gs-lib-1`) |
| `scripts/lib/` | Idle / load / net / backup helpers |
| `scripts/install-to-local.sh` / `uninstall-from-local.sh` / `verify-graceful-shutdown.sh` | Deploy |
| `scripts/test/test-policy-math.sh` | Offline policy smoke |
| `config/example.config` | Defaults |
| `systemd/user/*.example` | User oneshot + 30s timer |

Architecture: [docs/architecture/](docs/architecture/) · [ADR-001](docs/architecture/ADR-001-graceful-shutdown-policy.md) · [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md).

## Limits & safety

This can power off the machine. Hard stops and scope:

- **Platform:** GNOME Wayland with Mutter idle only. KDE / X11 idle are unsupported.
- **Network:** bulk RX/TX on the **default-route** iface only (VPN-safe; never sums tunnel + wifi).
- **Backup:** optional Ubuntu Déjà Dup / `duplicity` stay-awake (`BACKUP_CHECK_ENABLED=1`); harmless if those processes never appear.
- **Kill-switches:** `touch ~/.config/graceful-shutdown/inhibit`, `POWEROFF_ENABLED=0`, or `systemctl --user stop idle-low-load-shutdown.timer`.
- **Defaults:** shipped `POWEROFF_ENABLED=0`. v0.3 is extract-installable; a real poweroff soak for v1.0 is a human gate.
- This GitHub repo is the **release source** for tagged releases and public docs — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).

Optional tip jar: [ko-fi.com/alkitect](https://ko-fi.com/alkitect/?hidefeed=true&widget=true&embed=true)
