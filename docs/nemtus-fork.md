# NEMTUS fork of SteveLTN/https-portal

This repository is the NEMTUS fork of
[`SteveLTN/https-portal`](https://github.com/SteveLTN/https-portal). It exists so NEMTUS can
ship a patched image without waiting for an upstream release: upstream has no CI and
publishes `steveltn/https-portal` by hand, so a merged security fix is not available until
the maintainer tags and pushes it.

The fork publishes the same image to GHCR as `ghcr.io/nemtus/https-portal`.

## Branches

| Branch | Purpose |
|---|---|
| `master` | Pure mirror of upstream `master`. Never commit NEMTUS files here. Cut branches for upstream pull requests from it. |
| `nemtus` | Default branch. `master` plus the NEMTUS layer below. Releases are tagged here. |

The NEMTUS layer is deliberately small:

- `.github/workflows/nemtus-image.yml` — build, smoke test and publish to GHCR
- `.github/scripts/smoke-test.sh` — the smoke test, runnable locally
- `docs/nemtus-fork.md` — this file

Anything else that differs from upstream should be a fix that is also proposed upstream.

## Syncing with upstream

Bring upstream changes into `nemtus` with a **merge commit, never a squash or rebase**, so
ancestry is preserved for later syncs:

```bash
git fetch https://github.com/SteveLTN/https-portal.git master
git switch master && git merge --ff-only FETCH_HEAD && git push origin master
git switch nemtus && git merge --no-ff master
```

A fix that upstream has not merged yet can be merged into `nemtus` from its pull request
branch the same way. When upstream later merges it, the next sync resolves cleanly.

## Releasing

1. Make sure the version in `fs_overlay/etc/cont-init.d/00-welcome` is the one to release.
2. Tag the commit on `nemtus` and push the tag:

   ```bash
   git tag nemtus-v1.25.7 && git push origin nemtus-v1.25.7
   ```

The `nemtus-` prefix keeps NEMTUS tags apart from upstream's `X.Y.Z` tags. The workflow
fails if the tag version does not match the `00-welcome` banner.

For `nemtus-v1.25.7` the image is published as `:1.25.7`, `:1.25`, `:1`, `:latest` and
`:sha-<sha>`, for the same platforms as upstream (`linux/386`, `linux/amd64`,
`linux/arm/v7`, `linux/arm64/v8`), with SBOM and provenance attestations.

To release again without a new upstream version (for example to pick up base image
updates), either re-run the workflow on the existing tag with `push: true`, or push a
`nemtus-v1.25.7-2` tag, which additionally publishes `:1.25.7-2`.

## One-time repository setup

- Enable GitHub Actions on the fork (forks have them disabled by default).
- Set the default branch to `nemtus` (`workflow_dispatch` only works for workflows on the
  default branch).
- After the first publish, set the `https-portal` package visibility to public if it should
  be pullable without authentication.

## Testing

```bash
docker build -t https-portal:ci .
.github/scripts/smoke-test.sh https-portal:ci
```

The smoke test starts the image with `STAGE=local` and checks the nginx version, the
version banner, the HTTP to HTTPS redirect and the welcome page over HTTP/2 and HTTP/1.1.
Upstream's feature specs need a public domain and a real certificate issuance, so they are
not run in CI.
