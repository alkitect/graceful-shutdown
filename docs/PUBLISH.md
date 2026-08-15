# Publish notes

Before tag: README must pass `./scripts/ci-check.sh` (required H2s + README ban tokens + Ko-fi `FUNDING.yml` / tip link). See [CONTRIBUTING.md](../CONTRIBUTING.md) § README conventions.

First public tag: v0.3.3

Default first tag is 0.1.0. Never copy another alkitect repo’s tag. Use `RC-BEFORE-1.0` in this file only for an intentional 0.9.x RC.

```bash
./scripts/ci-check.sh
git tag -a v0.3.3 -m "v0.3.3"
git push origin main
git push origin v0.3.3
```

Repo URL: `https://github.com/alkitect/graceful-shutdown`

## GitHub About

| Field | Value |
|-------|--------|
| Description | Power off an idle, quiet Ubuntu GNOME desktop after a cancelable notification |
| Website | _(empty — tip via README Ko-fi badge)_ |
| Topics | `linux`, `ubuntu`, `gnome`, `systemd`, `power-management`, `wayland` |

```bash
gh repo edit alkitect/graceful-shutdown \
  --description "Power off an idle, quiet Ubuntu GNOME desktop after a cancelable notification" \
  --homepage "" \
  --add-topic linux --add-topic ubuntu --add-topic gnome \
  --add-topic systemd --add-topic power-management --add-topic wayland
```

Sidebar (manual if shown): Releases ✓ · Packages ✗ · Deployments ✗

### v1.0.0 human gate (after extract)

From this checkout:

1. `./scripts/install-to-local.sh`
2. Set `DRY_RUN=1` in config; enable timer; confirm healthy `check.log` / journal (no unexpected poweroff).
3. When ready, set `POWEROFF_ENABLED=1` and drop `DRY_RUN` for real poweroff policy.
4. Tag `v1.0.0` and push.
