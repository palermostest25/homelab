#!/usr/bin/env bash
# Reboot-verification for iVentoy (Proxmox guest 107). See PJA-29.
#
# Proves the three bind mounts and the service come back unattended after a
# cold boot of the Proxmox host. Run it FROM A WORKSTATION, after 192.168.1.3
# has finished booting -- it only needs SSH to the hypervisor.
#
#   ./verify-reboot.sh            # verify only
#   ./verify-reboot.sh --baseline # same checks, labelled as a pre-reboot baseline
#
# Exit 0 = PASS on every criterion, exit 1 = at least one FAIL.
# Read-only: it never reboots anything and never writes to the host.

set -uo pipefail

PVE_HOST="${PVE_HOST:-paperclip@192.168.1.3}"
GUEST_URL="${GUEST_URL:-http://192.168.1.20:26000/}"
CTID=107

# Expected ISO counts per mount point. A zero means the mount did not come back
# -- that is the exact failure this test exists to catch.
EXPECT_IMAGES=16
EXPECT_IMAGES_UPDATED=10
EXPECT_RESCUE=30

# iVentoy indexes ~255 ISOs over CIFS before it opens :26000. Polling sooner
# reports a false outage on every reboot.
HTTP_GRACE_SECS="${HTTP_GRACE_SECS:-120}"

fails=0

ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
head2() { printf '\n== %s ==\n' "$*"; }

pve() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$PVE_HOST" "$@"; }

if [ "${1:-}" = "--baseline" ]; then
  printf 'iVentoy reboot check -- BASELINE (pre-reboot) -- %s\n' "$(date -Is)"
else
  printf 'iVentoy reboot check -- %s\n' "$(date -Is)"
fi
printf 'hypervisor: %s   guest: %s\n' "$PVE_HOST" "$GUEST_URL"

# ---------------------------------------------------------------------------
head2 "1. Host CIFS mounts came back on their own"

for unit in 'mnt-images.mount' 'mnt-images\x2dupdated.mount'; do
  state=$(pve "systemctl is-active '$unit'" 2>&1 | tr -d '\r')
  printf '  systemctl is-active %-28s -> %s\n' "$unit" "$state"
  if [ "$state" = "active" ]; then
    ok "$unit is active"
  else
    bad "$unit is '$state', expected 'active' -- the fstab entry lost the race with TrueNAS"
  fi
done

# Surface the fstab options too: until these carry _netdev and
# x-systemd.automount, a pass here is luck rather than durability.
printf '\n  /etc/fstab CIFS entries:\n'
pve "grep -E '192\.168\.1\.2/(images|images-updated)' /etc/fstab" 2>&1 | sed 's/^/    /'

# ---------------------------------------------------------------------------
head2 "2. Guest $CTID started on boot and its config still parses"

cfg=$(pve "sudo pct config $CTID" 2>&1)
printf '%s\n' "$cfg" | sed 's/^/  /'
if printf '%s' "$cfg" | grep -q 'unable to parse value'; then
  bad "pct config $CTID emits parse warnings -- the PJA-26 fix did not survive"
else
  ok "pct config $CTID parses with zero warnings"
fi

status=$(pve "sudo pct status $CTID" 2>&1 | tr -d '\r')
printf '  pct status %s -> %s\n' "$CTID" "$status"
if [ "$status" = "status: running" ]; then
  ok "guest $CTID is running"
else
  bad "guest $CTID is '$status', expected 'status: running' -- check onboot: 1"
fi

# ---------------------------------------------------------------------------
head2 "3. All three mount points are attached with the right data"

counts=$(pve "sudo pct exec $CTID -- sh -c 'for d in Images Images-Updated Rescue; do echo \"\$d: \$(ls -1 /root/iventoy/iso/\$d 2>/dev/null | wc -l)\"; done'" 2>&1 | tr -d '\r')
printf '%s\n' "$counts" | sed 's/^/  /'

check_count() {
  local label=$1 expect=$2
  local got
  got=$(printf '%s\n' "$counts" | sed -n "s/^${label}: //p")
  if [ "$got" = "$expect" ]; then
    ok "$label has $got entries (expected $expect)"
  elif [ "$got" = "0" ]; then
    bad "$label is EMPTY -- its mount did not come back"
  elif [ -z "$got" ]; then
    bad "$label produced no output -- could not read the mount point"
  else
    bad "$label has $got entries, expected $expect"
  fi
}

check_count Images         "$EXPECT_IMAGES"
check_count Images-Updated "$EXPECT_IMAGES_UPDATED"
check_count Rescue         "$EXPECT_RESCUE"

# ---------------------------------------------------------------------------
head2 "4. iVentoy is serving"

printf '  polling %s for up to %ss (cold-start indexing grace)\n' "$GUEST_URL" "$HTTP_GRACE_SECS"
code=000
deadline=$(( $(date +%s) + HTTP_GRACE_SECS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$GUEST_URL" || echo 000)
  [ "$code" = "200" ] && break
  sleep 5
done
printf '  http_code -> %s\n' "$code"
if [ "$code" = "200" ]; then
  ok "iVentoy answers 200 on :26000"
else
  bad "iVentoy returned '$code' after ${HTTP_GRACE_SECS}s, expected 200"
  printf '  last lines of the guest indexing log:\n'
  pve "sudo pct exec $CTID -- tail -n 20 /root/iventoy/log/log.txt" 2>&1 | sed 's/^/    /'
fi

# A 200 on its own is not health: with the mounts detached iVentoy still answers
# 200 and serves nothing. That was the pre-PJA-26 state.
if [ "$code" = "200" ] && printf '%s' "$counts" | grep -qE ': 0$'; then
  bad "iVentoy answers 200 but at least one mount point is empty -- serving nothing (the pre-PJA-26 failure mode)"
fi

# ---------------------------------------------------------------------------
head2 "Verdict"
if [ "$fails" -eq 0 ]; then
  echo "PASS -- every criterion met."
  exit 0
fi
echo "FAIL -- $fails criteria failed."
echo "If a mount or a count failed, harden both /etc/fstab CIFS entries with"
echo "  _netdev,x-systemd.automount,x-systemd.mount-timeout=30"
echo "and re-run this check across another cold boot. Owner: Warden."
exit 1
