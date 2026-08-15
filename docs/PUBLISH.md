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

