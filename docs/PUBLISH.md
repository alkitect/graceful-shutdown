# Publish notes

Before tag: README must pass `./scripts/ci-check.sh` (required H2s + README ban tokens + Ko-fi `FUNDING.yml` / tip link). See [CONTRIBUTING.md](../CONTRIBUTING.md) § README conventions.

README variant: A

First public tag: v0.3.3

Latest tag: **v0.4.0** (two-phase load default; moderate AFK CPU can power off)

Default first tag is 0.1.0. Never copy another alkitect repo’s tag. Use `RC-BEFORE-1.0` in this file only for an intentional 0.9.x RC.

```bash
./scripts/ci-check.sh
git tag -a v0.4.0 -m "v0.4.0"
git push origin main v0.4.0
gh release create v0.4.0 --title "v0.4.0" --notes-file - <<'EOF'
## 0.4.0

Default two-phase load: critical CPU gate then 3-min rolling avg. Moderate AFK background CPU can power off; GPU, bulk net, and backup still pause. Grace uses instant critical/spike only. Legacy: PHASE_LOAD_ENABLED=0.
EOF
```

Repo URL: `https://github.com/alkitect/graceful-shutdown`

## GitHub About

| Field | Value |
|-------|--------|
| Description | Power off an idle Ubuntu GNOME desktop when load gates pass, after a cancelable notification |
| Website | _(empty — tip via README Ko-fi badge)_ |
| Topics | `linux`, `ubuntu`, `gnome`, `systemd`, `power-management`, `wayland` |

```bash
gh repo edit alkitect/graceful-shutdown \
  --description "Power off an idle Ubuntu GNOME desktop when load gates pass, after a cancelable notification" \
  --homepage "" \
  --add-topic linux --add-topic ubuntu --add-topic gnome \
  --add-topic systemd --add-topic power-management --add-topic wayland
```
