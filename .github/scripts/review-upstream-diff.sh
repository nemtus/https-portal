#!/usr/bin/env bash
# Mechanical review of an upstream diff before it is merged into the NEMTUS branch.
#
# Usage: .github/scripts/review-upstream-diff.sh <base> <head>
#
# Prints a Markdown report on stdout and classifies the diff through the exit status:
#   0  routine  - only version lines changed (nginx, s6-overlay, docker-gen, acme-tiny,
#                 the 00-welcome banner)
#   3  review   - anything else; the report lists what to look at
#   4  blocked  - the diff touches .github/, which would run with this repository's
#                 privileges once merged; mirror-sync refuses to open a pull request
#
# This is a tripwire, not a malware detector: it surfaces the obvious signs (new download
# hosts, pipe-to-shell, binaries, opaque blobs, changes to startup scripts) so the human
# review of the sync pull request starts in the right place. A change it calls "routine"
# still has to be read.
#
# It only reads git objects. It never checks out or executes anything from <head>.
set -euo pipefail

base="${1:?usage: review-upstream-diff.sh <base> <head>}"
head="${2:?usage: review-upstream-diff.sh <base> <head>}"

routine_files='Dockerfile fs_overlay/etc/cont-init.d/00-welcome'
routine_line='^(ARG +DIST=nginx:[0-9]+\.[0-9]+\.[0-9]+|ENV +(S6_OVERLAY_VERSION|DOCKER_GEN_VERSION|ACME_TINY_VERSION)=v?[0-9]+(\.[0-9]+)*|HTTPS-PORTAL v[0-9]+\.[0-9]+\.[0-9]+)$'
suspicious='(curl|wget)[^|;&]*\|[[:space:]]*(ba|z|da)?sh|base64[[:space:]]+(-d|--decode)|\beval\b|/dev/tcp/|\bnc[[:space:]]+-|\bncat\b|\bsocat\b|chmod[[:space:]]+[0-7]*[4267][0-7]{3}\b|chmod[[:space:]]+[ug]?\+s|authorized_keys|\bcrontab\b|LD_PRELOAD|python[0-9.]*[[:space:]]+-c|perl[[:space:]]+-e|ruby[[:space:]]+-e|\bpip3?[[:space:]]+install|\bgem[[:space:]]+install|\bnpm[[:space:]]+(i|install)\b|--no-check-certificate|[[:space:]]-k[[:space:]]|--insecure'
url_host='https?://[A-Za-z0-9._-]+'

verdict=0
blocked=()
review=()
flag_review() { review+=("$1"); [ "${verdict}" -ge 3 ] || verdict=3; }
flag_blocked() { blocked+=("$1"); verdict=4; }
clip() { cut -c1-200; }

mapfile -t files < <(git diff --name-only "${base}" "${head}")

for file in "${files[@]}"; do
  case "${file}" in
    .github/*) flag_blocked "\`${file}\`" ;;
  esac
done

# Files outside the routine set, and non-version lines inside it.
for file in "${files[@]}"; do
  if [[ " ${routine_files} " == *" ${file} "* ]]; then
    while IFS= read -r line; do
      [ -n "${line}" ] || continue
      if ! grep -Eq "${routine_line}" <<< "${line:1}"; then
        flag_review "\`${file}\`: non-version line \`$(clip <<< "${line}")\`"
      fi
    done < <(git diff -U0 "${base}" "${head}" -- "${file}" | grep -E '^[+-]' | grep -Ev '^(\+\+\+|---) ' || true)
    continue
  fi
  case "${file}" in
    .github/*) ;;
    fs_overlay/*) flag_review "\`${file}\`: changed (shipped inside the image)" ;;
    *) flag_review "\`${file}\`: changed" ;;
  esac
done

added="$(git diff -U0 "${base}" "${head}" | grep -E '^\+' | grep -Ev '^\+\+\+ ' || true)"

# Hosts that appear in added lines but nowhere in the base tree.
known_hosts="$(git grep -hoEI "${url_host}" "${base}" -- . 2>/dev/null | sort -u || true)"
while IFS= read -r host; do
  [ -n "${host}" ] || continue
  if ! grep -qxF "${host}" <<< "${known_hosts}"; then
    flag_review "new host in added lines: \`${host}\`"
  fi
done < <(grep -oE "${url_host}" <<< "${added}" | sort -u || true)

while IFS= read -r line; do
  [ -n "${line}" ] || continue
  flag_review "suspicious pattern: \`$(clip <<< "${line}")\`"
done < <(grep -E -- "${suspicious}" <<< "${added}" || true)

if grep -Eq '[A-Za-z0-9+/=]{120,}' <<< "${added}"; then
  flag_review 'added line with a long opaque string (120+ base64-like characters)'
fi

while IFS=$'\t' read -r adds dels file; do
  if [ "${adds}" = '-' ] && [ "${dels}" = '-' ]; then
    flag_review "\`${file}\`: binary file"
  fi
done < <(git diff --numstat "${base}" "${head}")

while IFS= read -r line; do
  [ -n "${line}" ] || continue
  flag_review "file mode: \`${line# }\`"
done < <(git diff --summary "${base}" "${head}" | grep -E 'mode change|create mode 100755|create mode 120000' || true)

echo "### Upstream diff review (\`$(git rev-parse --short "${base}")..$(git rev-parse --short "${head}")\`)"
echo
case "${verdict}" in
  0) echo '**Routine**: only version lines changed.' ;;
  3) echo '**Needs review**: the diff goes beyond version lines.' ;;
  4) echo '**Blocked**: the diff touches `.github/`.' ;;
esac
echo
echo '```'
git diff --stat "${base}" "${head}" | cut -c1-160
echo '```'
if [ "${#blocked[@]}" -gt 0 ]; then
  echo
  echo 'Files under `.github/` (these would run with this repository'"'"'s privileges):'
  echo
  printf -- '- %s\n' "${blocked[@]}" | head -n 50
fi
if [ "${#review[@]}" -gt 0 ]; then
  echo
  echo 'Look at:'
  echo
  printf -- '- %s\n' "${review[@]}" | head -n 80
  [ "${#review[@]}" -le 80 ] || echo "- ... and $(( ${#review[@]} - 80 )) more"
fi
echo
echo '_Mechanical check only. It catches obvious signs, not subtle changes; read the diff._'

exit "${verdict}"
