# Graceful shutdown (idle + low load)

Powers off a Linux desktop only when you’re idle and the machine is quiet — after a notification you can cancel.

**Installed names:** binary `idle-low-load-shutdown`, user timer/service of the same name, XDG config `~/.config/graceful-shutdown`.

## What this does

Desktops often stay on overnight because timers either power off too aggressively (killing work) or never fire. This tool waits until input is idle, CPU/GPU and bulk network stay calm, and (optionally) Ubuntu Backup is not running — then notifies you and runs `systemctl poweroff`.

Shipped config keeps **poweroff disabled** (`POWEROFF_ENABLED=0`). Install and verify first; only flip that when you’re ready.

## Who this is for

- Ubuntu + **GNOME Wayland** (Mutter IdleMonitor)
- You want automatic poweroff without killing downloads or backups mid-run

**Not for:** KDE, X11-only idle, always-on servers.

## Quick start

```bash
git clone https://github.com/alkitect/graceful-shutdown.git
cd graceful-shutdown
./scripts/install-to-local.sh
# Review ~/.config/graceful-shutdown/config — keep POWEROFF_ENABLED=0 until ready
systemctl --user enable --now idle-low-load-shutdown.timer
```

Primary safety default: leave `POWEROFF_ENABLED=0`. Use `DRY_RUN=1` temporarily for soak logging (shipped example has `DRY_RUN=0`; primary gate is `POWEROFF_ENABLED`).

Optional: `./scripts/install-to-local.sh --enable-automation` (requires `POWEROFF_ENABLED=1`; enables the timer only).

Prerequisites: GNOME Wayland, `gdbus`, `systemd --user`, `loginctl`, `ip`, `notify-send`, `flock`, `timeout`, and user-session polkit rights for `systemctl poweroff`.

## Check it works

```bash
GS_TOPIC_ROOT="$PWD" ./scripts/verify-graceful-shutdown.sh
DRY_RUN=1 ~/.local/bin/idle-low-load-shutdown
./scripts/test/test-policy-math.sh
./scripts/ci-check.sh
```

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

- **Desktop class:** GNOME Wayland with Mutter IdleMonitor only. KDE / X11 idle are unsupported.
- **Network:** bulk RX/TX on the **default-route** iface only (VPN-safe; never sums tunnel + wifi).
- **Backup:** optional Ubuntu Déjà Dup / `duplicity` stay-awake (`BACKUP_CHECK_ENABLED=1`); harmless if those processes never appear.
- **Kill-switches:** `touch ~/.config/graceful-shutdown/inhibit`, `POWEROFF_ENABLED=0`, or `systemctl --user stop idle-low-load-shutdown.timer`.
- **Validated on:** Ubuntu + GNOME Wayland (not required). v0.3 is extract-installable; a real poweroff soak for v1.0 is a human gate.
- This GitHub repo is the **release source** for tagged releases and public docs — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
