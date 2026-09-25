# ADR-001: Idle graceful shutdown via user timer + multi-gate policy

## Status

Accepted — 2026-07-14 (public extract scrubbed 2026-08-15); amended 2026-09-25 (two-phase load default)

## Context

Automatic poweroff after ~15 minutes away is useful only when the machine is not doing hard work (locked desktop OK). Moderate background CPU (filesystem helpers, idle containers, light daemons) should not block poweroff while you are away. Downloads, long GPU jobs, and ambient GPU noise must still keep the machine awake. An earlier approach used a systemd user timer with fixed `OnBootSec` / `OnUnitActiveSec` and bare `systemctl poweroff`, which powered off while the user was active.

Constraints: GNOME Wayland, preference for bash + user systemd (no permanent privileged daemon), optional VPN on the default route, dual-GPU hosts with non-zero ambient `gpu_busy_percent`.

## Decision

1. **User systemd timer (~30s)** invokes a oneshot checker — not logind `IdleAction` and not a fixed “poweroff every N minutes” timer.
2. **Gates (all required):** Mutter input idle ≥ 1 min → effective load streak ≥ 14 min (pause clock on busy, do not wipe) → grace → `systemctl poweroff`.
3. **Load busy (default `PHASE_LOAD_ENABLED=1`):** two-phase hysteretic CPU/GPU.
   - **Phase A** (first ~10 min of effective streak): pause only on **critical** CPU (`CPU_PHASE_A_MAX_PCT`, default 65) or GPU above `GPU_MAX_PCT` (optional VRAM).
   - **Phase B** (remainder): pause if 3‑min rolling avg CPU/GPU exceeds Phase B caps, or any sample spikes above `CPU_PHASE_B_SPIKE_MAX_PCT`, or instant GPU/VRAM busy. Fewer than 5 window samples: skip avg; still apply spike + critical.
   - Leave busy when the same enter-busy predicate is false for `HYSTERESIS_OK_POLLS` (no ≤7% floor requirement in phase mode).
   - **OR** sustained bulk RX/TX on the **default-route network iface** (~200 KiB/s × 2 polls) **OR** Ubuntu Backup **work** active.
   - Legacy: `PHASE_LOAD_ENABLED=0` restores single-threshold `CPU_MAX_PCT` / idle floors; optional soft `LOAD_WINDOW_*` only in that mode. When phase mode is on, `LOAD_WINDOW_ENABLED` / `window_warmup` are no-ops for pause decisions.
4. **Grace / poweroff abort:** instant-only critical/spike/GPU/VRAM (or sample failure fail-closed). Phase B rolling avg does **not** cancel grace. Sample `-` aborts poweroff.
5. **Safety:** `POWEROFF_ENABLED`, `DRY_RUN`, grace notification, inhibit file, honor `systemd-inhibit` shutdown blockers, `flock` + `TimeoutStartSec`.

## Consequences

### Positive

- Lock-screen compatible (Mutter idletime).
- Moderate AFK background CPU can complete the ~15 min path and power off (product intent).
- Large downloads keep the machine awake without treating game chat as busy.
- VPN does not double-count tunnel + wifi (default-route iface).
- Ambient GPU blips pause rather than restart the 14‑minute countdown indefinitely.

### Negative / tradeoffs

- Long **CPU-only** jobs left running while AFK may be powered off after ~15 min + grace; use `~/.config/graceful-shutdown/inhibit`, `PHASE_LOAD_ENABLED=0`, unlock/input, GPU load, or bulk net to stay awake.
- Sparse 30s sampling ≈ rough duty cycle, not continuous utilization.
- Default-route change (VPN toggle) forces net counter resync (one poll of blindness).
- User must calibrate Phase / GPU / net floors for their hardware and link speed.
- Déjà Dup may leave `deja-dup --backup` alive after work finishes (Finished dialog); default policy does not treat that as busy (`BACKUP_TREAT_UI_PROCESS=0`).

## Related

- [README.md](../../README.md)
- [docs/IMPLEMENTATION.md](../IMPLEMENTATION.md)
