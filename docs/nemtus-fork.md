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
- `.github/workflows/mirror-sync.yml` — daily upstream sync and release watch
- `.github/scripts/smoke-test.sh` — the smoke test, runnable locally
- `.github/scripts/review-upstream-diff.sh` — mechanical review of an upstream diff
- `docs/nemtus-fork.md` — this file

Anything else that differs from upstream should be a fix that is also proposed upstream.

## Automation

`mirror-sync.yml` runs daily (and on demand) and does two things.

**Sync.** When upstream `master` has commits that `nemtus` lacks, it:

1. Reviews the diff with `review-upstream-diff.sh` and classifies it:
   - `routine` — only version lines changed (nginx, s6-overlay, docker-gen, acme-tiny, the
     `00-welcome` banner);
   - `needs review` — anything else; the report lists new download hosts, pipe-to-shell and
     similar patterns, binaries, opaque strings, mode changes and every file outside the
     version lines;
   - `blocked` — the diff touches `.github/`. Merged, those files would run with this
     repository's privileges, so the run fails and nothing is pushed. Review upstream by
     hand and sync manually if it is legitimate.
2. Fast-forwards the `master` mirror.
3. Waits out a cooldown of 3 days (`COOLDOWN_DAYS`) since upstream's branch last moved. A
   bad upstream change is usually noticed and reverted within days. For an urgent security
   fix, run the workflow manually with `skip_cooldown`.
4. Opens a pull request `sync/upstream-<sha>` into `nemtus`, titled `[routine]` or
   `[needs review]`, with the report in its body, and starts the `build` check on it.

**Release watch.** Reports when upstream's latest release is not contained in the latest
`nemtus-v*` release, with the tag to push. It never tags or publishes.

Notifications go to Discord through the repository secret `DISCORD_WEBHOOK_URL` (skipped
when it is not set): failures, new upstream commits, an opened sync pull request, and a
pending release (on the day upstream releases, then every Monday).

The review script is a tripwire, not a malware detector, and it does not see what the
Dockerfile downloads at build time (the base image and release archives are fetched by
version, without checksums). The gates that matter are human: reading the sync pull
request before merging it, and pushing the signed release tag. `nemtus-image.yml` refuses
to publish a commit that is not on `nemtus`.

## Syncing with upstream by hand

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
- Add the repository secret `DISCORD_WEBHOOK_URL` for notifications.
- Rulesets: `nemtus` requires a pull request (merge commits only) and the `build` check;
  `master` and all tags cannot be deleted or force-pushed; creating `nemtus-v*` tags is
  restricted to admins.

## Testing

```bash
docker build -t https-portal:ci .
.github/scripts/smoke-test.sh https-portal:ci
```

The smoke test starts the image with `STAGE=local` and checks the nginx version, the
version banner, the HTTP to HTTPS redirect and the welcome page over HTTP/2 and HTTP/1.1.
Upstream's feature specs need a public domain and a real certificate issuance, so they are
not run in CI.
