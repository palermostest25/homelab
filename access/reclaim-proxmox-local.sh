#!/usr/bin/env bash
# Reclaim space on the Proxmox `local` dir storage (192.168.1.3, PJA-27).
#
# `local` is a dir storage on / (pve-root). It went to 93.7% during the PJA-12
# inventory. This script performs the reclaim steps that are *safe by
# construction* — it touches only logs, caches, orphaned temp dirs, and ISO /
# template volumes that no guest config references.
#
# It never touches a guest disk. It cannot: every deletion is either a
# Proxmox-native `pvesm free` on an `iso/` or `vztmpl/` volid, or an rm under a
# literal /var/tmp prefix. Moving or freeing a guest volume is a separate,
# human-approved operation and is deliberately absent here.
#
# Idempotent and re-runnable: each step checks whether the work is already done
# and reports SKIP rather than failing. A second run is a no-op that still
# prints an accurate before/after.
#
# Usage:
#   access/reclaim-proxmox-local.sh              # dry run: report only
#   access/reclaim-proxmox-local.sh --apply      # actually reclaim
#
# Requires an approved access.HOMELAB_SSH_KEY_PROXMOX binding to the calling
# agent, and the PC_MEASURE / PC_RECLAIM_* aliases in
# access/sudoers.d/paperclip-proxmox installed on the host. Steps whose sudo
# rule is missing report BLOCKED, not FAIL — a missing grant is missing
# permission, not a broken host.

set -uo pipefail

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

HOST=192.168.1.3
TARGET_PCT=80

if [[ -z "${PAPERCLIP_API_URL:-}" || -z "${PAPERCLIP_API_KEY:-}" ]]; then
  echo "FATAL: PAPERCLIP_API_URL / PAPERCLIP_API_KEY not set. Run inside a heartbeat." >&2
  exit 2
fi

API_BASE="${PAPERCLIP_API_URL%/}"; API_BASE="${API_BASE%/api}"
SCRATCH="${PAPERCLIP_RUN_SCRATCH_DIR:-${PAPERCLIP_SCRATCH_DIR:-/tmp}}"
KEY="$SCRATCH/reclaim-pve-key"

cleanup() { rm -f "$KEY"; }
trap cleanup EXIT

# The fetch route takes the SHORT secret key as listed by
# GET /api/agents/me/secrets, not the full `homelab/...` name. Sending the full
# name returns 403, indistinguishable from a missing binding.
if ! curl -fsS -X POST -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
     "$API_BASE/api/agents/me/secrets/ssh-key-proxmox/value" \
   | python3 -c 'import sys,json; v=json.load(sys.stdin)["value"]; sys.stdout.write(v if v.endswith("\n") else v+"\n")' \
   > "$KEY" 2>/dev/null; then
  echo "BLOCKED: cannot read ssh-key-proxmox. Needs an approved access binding." >&2
  exit 3
fi
chmod 600 "$KEY"

sshq() {
  ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "paperclip@$HOST" "$@" 2>&1 \
    | grep -v '^Warning: Permanently added'
}

# Used percentage of `local` straight from pvesm, which is what the ticket's
# threshold refers to. df reports a higher number because it excludes the
# root-reserved blocks from its denominator.
local_pct() {
  sshq 'sudo pvesm status' | awk '$1=="local"{gsub(/%/,"",$NF); print $NF}'
}

step() { printf '%-52s %s\n' "$1" "$2"; }

echo "=== Proxmox local reclaim  (host $HOST, apply=$APPLY) ==="
BEFORE=$(local_pct)
echo "local before: ${BEFORE}% used"
echo

run() {  # run <label> <remote-command>
  local label=$1 cmd=$2
  if (( ! APPLY )); then step "$label" "DRY-RUN"; return; fi
  local out; out=$(sshq "$cmd")
  if grep -qi 'not allowed to execute\|sudo:.*command not found' <<<"$out"; then
    step "$label" "BLOCKED (sudo rule not installed)"
  elif grep -qi 'error\|denied\|failed' <<<"$out"; then
    step "$label" "FAIL: $(head -1 <<<"$out")"
  else
    step "$label" "OK"
  fi
}

# 1. systemd journal. Already within the long-standing PC_JOURNAL grant, so this
#    step works even before the PJA-27 sudoers extension lands.
run "journal vacuum -> 512M" 'sudo journalctl --no-pager --vacuum-size=512M'

# 2. apt cache. `apt-get clean` only empties /var/cache/apt/archives; it cannot
#    fetch, unpack or remove a package.
run "apt-get clean" 'sudo apt-get clean'

# 3. Orphaned vzdump temp dirs. These are left behind when a vzdump is
#    interrupted; a completed backup never leaves one. Both current ones predate
#    any running job by months.
run "rm orphaned /var/tmp/vzdumptmp*" 'sudo rm -rf /var/tmp/vzdumptmp*'
run "rm /var/tmp/.guestfs-0 cache" 'sudo rm -rf /var/tmp/.guestfs-0'

# 4. ISOs with no referencing guest. Recomputed live rather than hardcoded: an
#    ISO that someone attached since the last run must not be deleted. Anything
#    still referenced by a qm config is skipped.
echo
echo "--- unreferenced ISOs / templates ---"
REFS=$(sshq 'for id in $(sudo qm list | awk "NR>1{print \$1}"); do sudo qm config $id; done | grep -o "local:iso/[^,]*"')
for vol in $(sshq 'sudo pvesm list local' | awk '$1 ~ /^local:iso\//{print $1}'); do
  if grep -qxF "$vol" <<<"$REFS"; then
    step "$vol" "SKIP (attached to a guest)"
  else
    run "free $vol" "sudo pvesm free $vol"
  fi
done

# Container templates are only read at `pct create` time, so an unused one is
# never load-bearing. The list is explicit rather than age-derived: debian-12,
# debian-13 and the current ubuntu cloudimg stay regardless of mtime.
for vol in $(sshq 'sudo pvesm list local' | awk '$1 ~ /^local:vztmpl\//{print $1}'); do
  case "$vol" in
    *debian-12*|*debian-13*|*ubuntu-26.04*) step "$vol" "SKIP (current)" ;;
    *) run "free $vol" "sudo pvesm free $vol" ;;
  esac
done

echo
AFTER=$(local_pct)
echo "local after:  ${AFTER}% used  (was ${BEFORE}%)"

if (( ! APPLY )); then
  echo "Dry run — nothing was deleted. Re-run with --apply."
  exit 0
fi

# Deliberately a non-zero exit, not a warning. The safe set does not add up to
# the target (see PJA-27), so a green exit here would misreport the host as
# fixed when the guest disks on `local` are still the real problem.
if awk -v a="$AFTER" -v t="$TARGET_PCT" 'BEGIN{exit !(a<t)}'; then
  echo "PASS: local is below ${TARGET_PCT}%."
else
  echo "INCOMPLETE: local is still at ${AFTER}%, above the ${TARGET_PCT}% target."
  echo "Safe deletions alone cannot reach it. The remaining space is guest disks"
  echo "on \`local\` — see PJA-27 for the move/free options, which need a human."
  exit 1
fi
