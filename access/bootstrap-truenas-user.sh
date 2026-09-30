#!/usr/bin/env bash
# bootstrap-truenas-user.sh -- create the `paperclip` service account on
# TrueNAS (192.168.1.2) through the middleware REST API (v2.0).
#
# Why the API and not useradd: a user created by editing /etc/passwd on TrueNAS
# is not in the config database, so it is lost on upgrade and absent after a
# config restore. The middleware is the only durable path.
#
# Idempotent: looks the user up first and PUTs an update instead of a duplicate
# POST if it already exists.
#
# Auth: pass a bearer token in TRUENAS_API_KEY, or basic-auth credentials in
# TRUENAS_USER / TRUENAS_PASSWORD. Credentials are read from the environment and
# are never echoed, never written to disk, and never passed on the command line
# (argv is world-readable via /proc).
#
# Usage:
#   TRUENAS_API_KEY=... ./bootstrap-truenas-user.sh \
#       --pubkey 'ssh-ed25519 AAAA... paperclip@truenas'
#
# NOTE ON SSH: as of 2026-09-28 sshd on 192.168.1.2 offers `publickey` only
# (verified: "Permission denied (publickey)"). Password bootstrap over SSH is
# not possible there -- this API path is the only way in.

set -euo pipefail

HOST="${TRUENAS_HOST:-192.168.1.2}"
BASE="https://${HOST}/api/v2.0"
USERNAME="paperclip"
PUBKEY=""
# Parent directory the account's home is created under. It must be on a pool:
# the middleware stores authorized_keys in the home, and the default /var/empty
# is read-only, so setting `sshpubkey` against it fails with
#   "The home directory is not writable. Leave this field blank."
# Override with TRUENAS_HOME_PARENT if /mnt/Apps is not the right pool.
HOME_PARENT="${TRUENAS_HOME_PARENT:-/mnt/Apps}"
# TrueNAS is a fixed appliance with a self-signed cert; -k is deliberate and
# scoped to this known LAN host.
CURL=(curl -sk --fail-with-body)

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

# python3 rather than jq: the Paperclip runner has python3 but no jq, and this
# script is expected to run from the runner as well as from a workstation.
command -v python3 >/dev/null 2>&1 || die "python3 is required"

while [ $# -gt 0 ]; do
  case "$1" in
    --pubkey) PUBKEY="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$PUBKEY" ] || die "--pubkey is required"
case "$PUBKEY" in
  ssh-ed25519\ *) : ;;
  *) die "--pubkey must be an ssh-ed25519 public key" ;;
esac
case "$PUBKEY" in
  *PRIVATE*) die "refusing: that looks like a PRIVATE key" ;;
esac

if [ -n "${TRUENAS_API_KEY:-}" ]; then
  CURL+=(-H "Authorization: Bearer ${TRUENAS_API_KEY}")
elif [ -n "${TRUENAS_USER:-}" ] && [ -n "${TRUENAS_PASSWORD:-}" ]; then
  CURL+=(-u "${TRUENAS_USER}:${TRUENAS_PASSWORD}")
else
  die "set TRUENAS_API_KEY, or TRUENAS_USER and TRUENAS_PASSWORD"
fi

info "checking API reachability"
"${CURL[@]}" "${BASE}/core/ping" >/dev/null || die "cannot reach or authenticate to ${BASE}"

# --- helpers ------------------------------------------------------------------
# Build the user payload. The public key is passed via env, not argv.
build_payload() {
  PC_PUBKEY="$PUBKEY" PC_USERNAME="$USERNAME" PC_CREATE="${1:-0}" \
  PC_HOME_PARENT="$HOME_PARENT" python3 - <<'PY'
import json, os
d = {
    "username": os.environ["PC_USERNAME"],
    "full_name": "Paperclip service account",
    # sshpubkey is the field the middleware uses to manage authorized_keys.
    # Setting it here is what makes key auth survive an upgrade.
    "sshpubkey": os.environ["PC_PUBKEY"],
    "password_disabled": True,
    "locked": False,
    "shell": "/usr/bin/bash",
    "smb": False,
}
# group_create and the home-creation fields are create-only; sending them on an
# update is either rejected or would move an existing home.
if os.environ.get("PC_CREATE") == "1":
    d["group_create"] = True
    # `home` is the PARENT here -- the middleware appends the username, so
    # /mnt/Apps becomes /mnt/Apps/paperclip. 0700 because only this account and
    # root have any business in it.
    d["home"] = os.environ["PC_HOME_PARENT"]
    d["home_create"] = True
    d["home_mode"] = "700"
print(json.dumps(d))
PY
}

# --- 1. Does the user already exist? -----------------------------------------
# The user list is fetched whole and filtered here rather than with middleware
# query-filters. On TrueNAS 25.10 both `?[["username","=","x"]]` and
# `?query-filters=[["username","=","x"]]` return [] for a user that demonstrably
# exists, which silently turns this script's update path into a duplicate
# create. The box has ~63 users; filtering client-side is cheap and correct.
lookup_id() {
  "${CURL[@]}" "${BASE}/user" | PC_USERNAME="$USERNAME" python3 -c '
import json, os, sys
for u in json.load(sys.stdin):
    if u.get("username") == os.environ["PC_USERNAME"]:
        print(u["id"]); break
'
}

EXISTING_ID="$(lookup_id)"

if [ -n "$EXISTING_ID" ]; then
  info "user '$USERNAME' exists (id ${EXISTING_ID}) -- updating in place"
  build_payload 0 | "${CURL[@]}" -X PUT "${BASE}/user/id/${EXISTING_ID}" \
    -H 'Content-Type: application/json' --data-binary @- >/dev/null
  info "updated"
else
  info "creating user '$USERNAME'"
  build_payload 1 | "${CURL[@]}" -X POST "${BASE}/user" \
    -H 'Content-Type: application/json' --data-binary @- \
    | python3 -c 'import json,sys; print("==> created id:", json.load(sys.stdin))'
fi

# --- 2. Confirm ---------------------------------------------------------------
info "verifying"
"${CURL[@]}" "${BASE}/user" | PC_USERNAME="$USERNAME" python3 -c '
import json, os, sys
r = [u for u in json.load(sys.stdin) if u.get("username") == os.environ["PC_USERNAME"]]
if not r:
    sys.exit("verification FAILED: user not found after write")
if len(r) > 1:
    sys.exit("verification FAILED: %d users named %s -- duplicate create" % (
        len(r), os.environ["PC_USERNAME"]))
u = r[0]
print("username=%s uid=%s home=%s locked=%s password_disabled=%s sshpubkey_set=%s" % (
    u.get("username"), u.get("uid"), u.get("home"), u.get("locked"),
    u.get("password_disabled"), bool(u.get("sshpubkey"))))
if not u.get("sshpubkey"):
    sys.exit("verification FAILED: sshpubkey is empty, key auth will not work")
'

# --- 3. Sudo on TrueNAS -------------------------------------------------------
# TrueNAS does NOT use /etc/sudoers.d for managed users -- the middleware
# regenerates sudo config from the user object, so a hand-dropped file does not
# survive. Scoped sudo is expressed with the user's `sudo_commands_nopasswd`
# field instead, e.g.
#
#   printf '{"sudo_commands_nopasswd":["/usr/bin/systemctl --no-pager status *"]}' \
#     | "${CURL[@]}" -X PUT "${BASE}/user/id/${ID}" \
#         -H 'Content-Type: application/json' --data-binary @-
#
# Left unset deliberately: on TrueNAS, service and dataset management should go
# through the middleware API under this account's own privileges rather than
# through shell sudo. Grant sudo here only when a concrete task proves it is
# needed, and record the reason in the README.
info "sudo: intentionally not granted on TrueNAS -- see README"
