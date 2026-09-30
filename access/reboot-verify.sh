#!/usr/bin/env bash
# Reboot-verify paperclip key access on all three lab hosts.
#
# Answers one question per host: after a cold boot, is the paperclip account
# still reachable on the key alone, with the expected uid and sudo drop-in?
#
# Read-only. Reboots nothing, changes nothing on any host. Safe to run any time;
# it is only *meaningful* when run after a host has actually rebooted, so it
# prints seconds-since-boot alongside each verdict and refuses to call a host
# reboot-verified when that host has not rebooted since the key was deployed.
#
# Usage:
#   access/reboot-verify.sh                  # all three hosts
#   access/reboot-verify.sh proxmox truenas  # named subset
#
# Requires an approved access.HOMELAB_SSH_KEY_* binding to the calling agent.
# Without it the secret fetch returns 403 and the host is reported BLOCKED, not
# PASS and not FAIL — an unreadable key is missing evidence, not a broken host.

set -uo pipefail

# Keys were deployed on this date (see access/README.md "Current status").
# A boot time at or before this is the pre-deploy boot: reaching the host proves
# the key works, but proves nothing about surviving a reboot.
KEY_DEPLOY_EPOCH=$(date -u -d '2026-09-29T00:00:00Z' +%s 2>/dev/null || echo 1790294400)

if [[ -z "${PAPERCLIP_API_URL:-}" || -z "${PAPERCLIP_API_KEY:-}" ]]; then
  echo "FATAL: PAPERCLIP_API_URL / PAPERCLIP_API_KEY not set. Run inside a heartbeat." >&2
  exit 2
fi

API_BASE="${PAPERCLIP_API_URL%/}"; API_BASE="${API_BASE%/api}"
SCRATCH="${PAPERCLIP_RUN_SCRATCH_DIR:-${PAPERCLIP_SCRATCH_DIR:-/tmp}}"

# host-key: name|address|secret short key|expected uid|extra check command
# The fetch route is /api/agents/me/secrets/:key/value where :key is the SHORT
# key as listed by GET /api/agents/me/secrets (e.g. ssh-key-proxmox), NOT the
# full secret name. Sending the full name (even %2F-encoded) returns 403
# "Secret access is not granted", indistinguishable from a missing binding.
HOSTS=(
  "proxmox|192.168.1.3|ssh-key-proxmox|1000|sudo -n pveversion"
  "truenas|192.168.1.2|ssh-key-truenas|3006|ls -l \$HOME/.ssh/authorized_keys"
  "arcane|192.168.1.10|ssh-key-arcane|1000|id paperclip; groups paperclip"
)

# URL-encode the secret name. Names contain a '/', which is a path separator on
# the /api/agents/me/secrets/:name/value route -- sending it raw returns
# {"error":"API route not found"} (a routing 404), which is easy to misread as
# "secret does not exist". It must be %2F.
# NOTE 2026-09-29 (Warden Backup): the route actually takes the SHORT key
# (e.g. ssh-key-proxmox, as listed by GET /api/agents/me/secrets), not the full
# secret name. Sending the full name -- even %2F-encoded -- returns 403
# "Secret access is not granted", indistinguishable from a missing binding.
# TODO: retire urlencode() and pass the short key directly once HOSTS is updated.
urlencode() { printf '%s' "$1" | sed 's|/|%2F|g'; }

pass=0; fail=0; blocked=0
declare -a SUMMARY=()

want=("$@")
selected() {
  [[ ${#want[@]} -eq 0 ]] && return 0
  local h
  for h in "${want[@]}"; do [[ "$h" == "$1" ]] && return 0; done
  return 1
}

for row in "${HOSTS[@]}"; do
  IFS='|' read -r name addr secret want_uid extra <<<"$row"
  selected "$name" || continue

  echo "=============================================================="
  echo "HOST $name ($addr)  expected uid=$want_uid"
  echo "=============================================================="

  keyfile="$SCRATCH/id_${name}"
  # The value endpoint returns a JSON envelope {"key","value","version"} --
  # the keyfile must contain the extracted .value, not the raw JSON (ssh
  # fails on the envelope with "error in libcrypto").
  ( umask 077
    code=$(curl -s -w '%{http_code}' -o "$SCRATCH/raw_${name}" -X POST \
      -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
      "$API_BASE/api/agents/me/secrets/${secret}/value")
    echo -n "$code" > "$SCRATCH/code_${name}"
    if [[ "$code" == "200" ]]; then
      python3 -c "import sys,json; print(json.load(open('$SCRATCH/raw_${name}'))['value'], end='')" > "$keyfile"
    else
      head -c 200 "$SCRATCH/raw_${name}" > "$keyfile"
    fi
    rm -f "$SCRATCH/raw_${name}" )
  code=$(cat "$SCRATCH/code_${name}" 2>/dev/null || echo 000)

  if [[ "$code" != "200" ]]; then
    echo "  secret fetch: HTTP $code -- $(head -c 200 "$keyfile" 2>/dev/null)"
    echo "  VERDICT: BLOCKED (cannot read $secret; need an approved access.* binding)"
    SUMMARY+=("BLOCKED $name -- secret fetch HTTP $code")
    blocked=$((blocked+1)); rm -f "$keyfile" "$SCRATCH/code_${name}"; echo; continue
  fi
  chmod 600 "$keyfile"

  if ! grep -q 'PRIVATE KEY' "$keyfile"; then
    echo "  secret fetch: HTTP 200 but body is not a private key"
    echo "  VERDICT: BLOCKED (secret value is not usable key material)"
    SUMMARY+=("BLOCKED $name -- secret is not a private key")
    blocked=$((blocked+1)); rm -f "$keyfile" "$SCRATCH/code_${name}"; echo; continue
  fi

  out=$(timeout 30 ssh -i "$keyfile" \
        -o BatchMode=yes -o PasswordAuthentication=no -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o LogLevel=ERROR \
        "paperclip@$addr" \
        "echo __UID__=\$(id -u); echo __BOOT__=\$(date -d \"\$(uptime -s)\" +%s 2>/dev/null || echo 0); echo __IDFULL__=\$(id); echo '__EXTRA__'; $extra" 2>&1)
  rc=$?
  rm -f "$keyfile" "$SCRATCH/code_${name}"

  echo "--- ssh rc=$rc, raw output:"
  printf '%s\n' "$out" | sed 's/^/    /'

  if [[ $rc -ne 0 ]]; then
    echo "  VERDICT: FAIL (ssh did not succeed on the key alone; rc=$rc)"
    SUMMARY+=("FAIL $name -- ssh rc=$rc: $(printf '%s' "$out" | tail -1)")
    fail=$((fail+1)); echo; continue
  fi

  got_uid=$(printf '%s\n' "$out" | sed -n 's/^__UID__=//p' | head -1)
  boot=$(printf '%s\n' "$out"  | sed -n 's/^__BOOT__=//p' | head -1)
  extra_out=$(printf '%s\n' "$out" | sed -n '/^__EXTRA__$/,$p' | tail -n +2)

  ok=1
  if [[ "$got_uid" != "$want_uid" ]]; then
    echo "  uid: expected $want_uid, got '${got_uid:-<none>}'  -> FAIL"
    ok=0
  else
    echo "  uid: expected $want_uid, got $got_uid  -> ok"
  fi

  if [[ -z "${extra_out//[[:space:]]/}" ]]; then
    echo "  host check ('$extra') produced no output  -> FAIL"
    ok=0
  else
    echo "  host check ('$extra') produced output  -> ok"
  fi

  rebooted="unknown"
  if [[ -n "${boot:-}" && "${boot:-0}" != "0" ]]; then
    age=$(( $(date -u +%s) - boot ))
    echo "  booted $(date -u -d "@$boot" '+%Y-%m-%dT%H:%M:%SZ') (${age}s ago)"
    if (( boot > KEY_DEPLOY_EPOCH )); then rebooted="yes"; else rebooted="no"; fi
  else
    echo "  boot time: could not determine"
  fi

  if [[ $ok -eq 1 && "$rebooted" == "yes" ]]; then
    echo "  VERDICT: PASS (reboot-verified -- host booted after key deploy)"
    SUMMARY+=("PASS $name -- reboot-verified, uid=$got_uid")
    pass=$((pass+1))
  elif [[ $ok -eq 1 ]]; then
    echo "  VERDICT: PASS-LIVE / NOT REBOOT-VERIFIED (key works, but this host has"
    echo "           not rebooted since the key was deployed; rerun after a reboot)"
    SUMMARY+=("PASS-LIVE $name -- key works, no reboot since deploy (rebooted=$rebooted)")
  else
    echo "  VERDICT: FAIL (connected, but a criterion above did not hold)"
    SUMMARY+=("FAIL $name -- criterion failed, see output")
    fail=$((fail+1))
  fi
  echo
done

echo "=============================================================="
echo "SUMMARY"
echo "=============================================================="
for s in "${SUMMARY[@]}"; do echo "  $s"; done
echo
echo "  pass=$pass fail=$fail blocked=$blocked"

# Exit non-zero on a real failure or a missing grant, so a routine notices.
if (( fail > 0 )); then exit 1; fi
if (( blocked > 0 )); then exit 3; fi
exit 0
