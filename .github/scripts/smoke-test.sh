#!/usr/bin/env bash
# Smoke test for a built https-portal image.
#
# Usage: .github/scripts/smoke-test.sh <image>
#
# Starts the image with STAGE=local (self-signed certificate, no ACME traffic) and checks
# that it becomes healthy, runs the nginx version pinned in the Dockerfile, prints the
# version banner from 00-welcome, redirects HTTP to HTTPS and serves the welcome page over
# HTTP/2 and HTTP/1.1.
#
# Upstream's feature specs (spec/features) need a public domain, ports 80/443 and a real
# Let's Encrypt issuance, so they cannot run in CI; this covers the same ground as
# spec/features/local_stage_spec.rb.
set -euo pipefail

image="${1:?usage: smoke-test.sh <image>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
domain='smoke.test'
name="https-portal-smoke-$$"
timeout_seconds=300

expected_nginx="$(sed -n 's/^ARG  *DIST=nginx:\(.*\)$/\1/p' "${root}/Dockerfile")"
expected_version="$(sed -n 's/^HTTPS-PORTAL v\(.*\)$/\1/p' "${root}/fs_overlay/etc/cont-init.d/00-welcome")"
[ -n "${expected_nginx}" ] || { echo 'cannot read the nginx version from Dockerfile' >&2; exit 1; }
[ -n "${expected_version}" ] || { echo 'cannot read the version from 00-welcome' >&2; exit 1; }

fail() {
  echo "FAIL: $*" >&2
  echo '--- container logs (tail) ---' >&2
  docker logs "${name}" 2>&1 | tail -n 40 | cut -c1-300 >&2 || true
  exit 1
}
trap 'docker rm -f "${name}" >/dev/null 2>&1 || true' EXIT

docker run -d --name "${name}" \
  -p 127.0.0.1::80 -p 127.0.0.1::443 \
  -e "DOMAINS=${domain}" -e STAGE=local \
  "${image}" >/dev/null

deadline=$((SECONDS + timeout_seconds))
status=starting
while [ "${SECONDS}" -lt "${deadline}" ]; do
  status="$(docker inspect -f '{{.State.Health.Status}}' "${name}" 2>/dev/null || echo gone)"
  [ "${status}" = healthy ] && break
  [ "${status}" = gone ] && fail 'container exited'
  sleep 2
done
[ "${status}" = healthy ] || fail "container not healthy after ${timeout_seconds}s (status: ${status})"
echo 'ok: container is healthy'

actual_nginx="$(docker exec "${name}" nginx -v 2>&1)"
[ "${actual_nginx}" = "nginx version: nginx/${expected_nginx}" ] ||
  fail "expected nginx/${expected_nginx}, got '${actual_nginx}'"
echo "ok: ${actual_nginx}"

docker exec "${name}" nginx -t >/dev/null 2>&1 || fail 'nginx -t failed'
echo 'ok: nginx configuration is valid'

docker logs "${name}" 2>&1 | grep -qxF "HTTPS-PORTAL v${expected_version}" ||
  fail "banner 'HTTPS-PORTAL v${expected_version}' not found in the logs"
echo "ok: banner HTTPS-PORTAL v${expected_version}"

http_port="$(docker port "${name}" 80/tcp | head -n 1 | sed 's/.*://')"
https_port="$(docker port "${name}" 443/tcp | head -n 1 | sed 's/.*://')"

redirect="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' \
  --resolve "${domain}:${http_port}:127.0.0.1" "http://${domain}:${http_port}/")"
[ "${redirect}" = "301 https://${domain}/" ] || fail "unexpected HTTP response: '${redirect}'"
echo "ok: HTTP redirects to HTTPS (${redirect})"

for proto in http2 http1.1; do
  body="$(mktemp)"
  result="$(curl -sSk "--${proto}" -o "${body}" -w '%{http_code} %{http_version}' \
    --resolve "${domain}:${https_port}:127.0.0.1" "https://${domain}:${https_port}/")"
  case "${proto}" in
    http2) expected='200 2' ;;
    *) expected='200 1.1' ;;
  esac
  [ "${result}" = "${expected}" ] || fail "HTTPS over ${proto}: expected '${expected}', got '${result}'"
  grep -q 'Welcome to HTTPS-PORTAL!' "${body}" || fail "HTTPS over ${proto}: welcome page not served"
  rm -f "${body}"
  echo "ok: HTTPS over ${proto} serves the welcome page"
done

echo "smoke test passed: ${image}"
