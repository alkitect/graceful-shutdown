# Graceful shutdown (idle + low load)

Power off a Linux desktop only when **input is idle**, **CPU/GPU stay quiet**, **bulk network is calm**, and (optionally) **Ubuntu Backup is not working** — then after a grace notification.

**Installed names:** binary `idle-low-load-shutdown`, user timer/service of the same name, XDG config `~/.config/graceful-shutdown`.

## Scope (read first)

1. **Desktop class:** **GNOME Wayland** with Mutter IdleMonitor. KDE / X11 idle are unsupported.
2. **Safety defaults:** `POWEROFF_ENABLED=0` (primary gate) and `DRY_RUN=0` in the shipped example. Set `POWEROFF_ENABLED=1` only when ready; use `DRY_RUN=1` temporarily for soak logging.
3. **Gates:** input idle → effective low-load streak (pause clock on busy load/net/backup) → grace → `systemctl poweroff`.
4. **Network:** bulk RX/TX on the **default-route** iface only (VPN-safe; never sums tunnel + wifi).
5. **Backup:** optional Ubuntu Déjà Dup / `duplicity` stay-awake (`BACKUP_CHECK_ENABLED=1`); harmless if those processes never appear.
6. **Kill-switches:** `touch ~/.config/graceful-shutdown/inhibit`, `POWEROFF_ENABLED=0`, or `systemctl --user stop idle-low-load-shutdown.timer`.
7. **Validated upstream:** Ubuntu + GNOME Wayland (not required). v0.3 is extract-installable; host poweroff soak for v1.0 is a human gate.
8. **SSOT:** this repo is canonical for **releases** and public docs. See [CONTRIBUTING.md](CONTRIBUTING.md).

Architecture: [docs/architecture/](docs/architecture/) · [ADR-001](docs/architecture/ADR-001-graceful-shutdown-policy.md) · [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md).

## Prerequisites

- GNOME Wayland, `gdbus`, `systemd --user`, `loginctl`, `ip`, `notify-send`, `flock`, `timeout`
- User-session polkit rights for `systemctl poweroff`

## Install

```bash
git clone https://github.com/alkitect/graceful-shutdown.git
cd graceful-shutdown
./scripts/install-to-local.sh
# Review ~/.config/graceful-shutdown/config — keep POWEROFF_ENABLED=0 until ready
systemctl --user enable --now idle-low-load-shutdown.timer
```

Optional: `./scripts/install-to-local.sh --enable-automation` (requires `POWEROFF_ENABLED=1`; enables the timer only).

## Verify

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

## Layout

| Path | Role |
|------|------|
| `scripts/idle-low-load-shutdown.sh` | Checker (`CHECKER_VERSION=gs-lib-1`) |
| `scripts/lib/` | Idle / load / net / backup helpers |
| `scripts/install-to-local.sh` / `uninstall-from-local.sh` / `verify-graceful-shutdown.sh` | Deploy |
| `scripts/test/test-policy-math.sh` | Offline policy smoke |
| `config/example.config` | Defaults |
| `systemd/user/*.example` | User oneshot + 30s timer |

## Calibration tips

- Dual-GPU ambient noise: raise `GPU_MAX_PCT` or set `GPU_DRM_CARD` to the discrete card.
- VPN: leave `NET_IFACE` empty so the default route (tunnel when connected) is used.
- Thresholds: follow `check.log` / `verify-graceful-shutdown` while away with downloads / backups.

## License

MIT — see [LICENSE](LICENSE).
