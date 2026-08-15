# ADR-001: Idle graceful shutdown via user timer + multi-gate policy

## Status

Accepted — 2026-07-14 (public extract scrubbed 2026-08-15)

## Context

Automatic poweroff after ~15 minutes away is useful only when the machine is truly idle and not doing useful work (locked desktop OK; downloads / long GPU jobs / ambient GPU noise should not wipe progress incorrectly). An earlier approach used a systemd user timer with fixed `OnBootSec` / `OnUnitActiveSec` and bare `systemctl poweroff`, which powered off while the user was active.

Constraints: GNOME Wayland, preference for bash + user systemd (no permanent privileged daemon), optional VPN on the default route, dual-GPU hosts with non-zero ambient `gpu_busy_percent`.

## Decision

1. **User systemd timer (~30s)** invokes a oneshot checker — not logind `IdleAction` and not a fixed “poweroff every N minutes” timer.
2. **Gates (all required):** Mutter input idle ≥ 1 min → effective low-load streak ≥ 14 min (pause clock on busy, do not wipe) → grace → `systemctl poweroff`.
3. **Busy =** hysteretic CPU/GPU above thresholds **OR** sustained bulk RX/TX on the **default-route network iface** only (~200 KiB/s × 2 polls) **OR** Ubuntu Backup **work** active (`deja-dup.service` and/or `duplicity`; ignore `--gapplication-service` and, by default, lone `--backup` UI dialogs). Soft load window remains opt-in.
4. **Safety:** `POWEROFF_ENABLED`, `DRY_RUN`, grace notification, inhibit file, honor `systemd-inhibit` shutdown blockers, `flock` + `TimeoutStartSec`.

## Consequences

### Positive

- Lock-screen compatible (Mutter idletime).
- Large downloads keep the machine awake without treating game chat as busy.
- VPN does not double-count tunnel + wifi (default-route iface).
- Ambient GPU blips pause rather than restart the 14‑minute countdown indefinitely.

### Negative / tradeoffs

- Sparse 30s sampling ≈ rough duty cycle, not continuous utilization.
- Default-route change (VPN toggle) forces net counter resync (one poll of blindness).
- User must calibrate `GPU_MAX_PCT` / net floors for their hardware and link speed.
- Déjà Dup may leave `deja-dup --backup` alive after work finishes (Finished dialog); default policy does not treat that as busy (`BACKUP_TREAT_UI_PROCESS=0`).

## Related

- [README.md](../../README.md)
- [docs/IMPLEMENTATION.md](../IMPLEMENTATION.md)
