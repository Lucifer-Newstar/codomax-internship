# Workflows

GitHub only reads workflow files from `/.github/workflows/`, so the real files live there. This
folder documents them; do not copy them here (two copies drift).

| File | Purpose | Doc |
|---|---|---|
| [`/.github/workflows/ci.yml`](../../.github/workflows/ci.yml) | lint → test (PostgreSQL service) → docker build & smoke test | [`docs/pipeline.md`](../docs/pipeline.md#stages) |
| [`/.github/workflows/deploy.yml`](../../.github/workflows/deploy.yml) | main-only: push image to GHCR → OIDC → SSM deploy → verify | [`docs/pipeline.md`](../docs/pipeline.md#deploy-deployyml) |

Validate locally before pushing:

```bash
actionlint                                   # syntax + expression checks + shellcheck of run: blocks
yamllint -d '{extends: default, rules: {line-length: {max: 160}, document-start: disable, truthy: disable}}' .github/workflows/
```

Run CI locally with [`act`](https://github.com/nektos/act) (optional): `act pull_request -j lint`.
