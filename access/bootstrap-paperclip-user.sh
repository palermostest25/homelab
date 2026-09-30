#!/usr/bin/env bash
# bootstrap-paperclip-user.sh -- create the `paperclip` service account on a
# systemd/Linux host (Proxmox VE 192.168.1.3, arcane 192.168.1.10).
#
# Idempotent: safe to run repeatedly. Creates nothing that already exists,
# never duplicates an authorized_keys line, and validates sudoers before the
# drop-in is allowed to stay in place.
#
# NOT for TrueNAS (192.168.1.2) -- there the user must be created through the
# middleware API so it survives upgrades. Use bootstrap-truenas-user.sh.
#
# Usage, run as root on the target host:
#   ./bootstrap-paperclip-user.sh --pubkey 'ssh-ed25519 AAAA... paperclip@proxmox' \
#                                 --sudoers ./paperclip-proxmox \
#                                 [--docker-group]
#
# The PRIVATE key is never handled by this script and must never land on a host.

set -euo pipefail

PUBKEY=""
SUDOERS_SRC=""
ADD_DOCKER_GROUP=0
USERNAME="paperclip"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pubkey)        PUBKEY="${2:-}"; shift 2 ;;
    --sudoers)       SUDOERS_SRC="${2:-}"; shift 2 ;;
    --docker-group)  ADD_DOCKER_GROUP=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -n "$PUBKEY" ] || die "--pubkey is required"
[ -n "$SUDOERS_SRC" ] || die "--sudoers is required"
[ -f "$SUDOERS_SRC" ] || die "sudoers source not found: $SUDOERS_SRC"

case "$PUBKEY" in
  ssh-ed25519\ *) : ;;
  *) die "--pubkey must be an ssh-ed25519 public key (got something else)" ;;
esac
case "$PUBKEY" in
  *PRIVATE*) die "refusing: that looks like a PRIVATE key" ;;
esac

# --- 1. Account ---------------------------------------------------------------
if id -u "$USERNAME" >/dev/null 2>&1; then
  info "user '$USERNAME' already exists -- leaving as is"
else
  info "creating user '$USERNAME'"
  useradd --create-home --shell /bin/bash --comment "Paperclip service account" "$USERNAME"
fi

# No password is ever set. The account is key-only by construction.
# '!' in the password field locks password auth without locking the account
# itself (unlike `usermod -L --expiredate 1`, which would also block sudo -u).
passwd --lock "$USERNAME" >/dev/null

HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
[ -n "$HOME_DIR" ] || die "could not resolve home directory for $USERNAME"

# --- 2. authorized_keys -------------------------------------------------------
install -d -m 0700 -o "$USERNAME" -g "$USERNAME" "$HOME_DIR/.ssh"
AK="$HOME_DIR/.ssh/authorized_keys"
touch "$AK"

# Match on the key body (field 2), so re-running with the same key never
# appends a duplicate even if the trailing comment changed.
KEY_BODY="$(printf '%s' "$PUBKEY" | awk '{print $2}')"
if grep -qF -- "$KEY_BODY" "$AK" 2>/dev/null; then
  info "public key already present in authorized_keys -- not re-adding"
else
  info "installing public key"
  printf '%s\n' "$PUBKEY" >> "$AK"
fi
chown "$USERNAME:$USERNAME" "$AK"
chmod 0600 "$AK"

# --- 3. Scoped sudo -----------------------------------------------------------
# Validate into a staging file first. A broken drop-in in /etc/sudoers.d can
# break sudo for every user on the host, so it is never copied into place
# unvalidated.
STAGE="$(mktemp /tmp/paperclip-sudoers.XXXXXX)"
trap 'rm -f "$STAGE"' EXIT
cp "$SUDOERS_SRC" "$STAGE"
chmod 0440 "$STAGE"

info "validating sudoers drop-in"
if ! visudo -c -f "$STAGE"; then
  die "sudoers drop-in failed validation -- NOT installed, host left unchanged"
fi

install -m 0440 -o root -g root "$STAGE" /etc/sudoers.d/paperclip
info "installed /etc/sudoers.d/paperclip"

# Re-validate the whole sudoers tree, not just our fragment.
visudo -c >/dev/null || die "global sudoers validation failed after install"

# --- 4. Optional docker group -------------------------------------------------
if [ "$ADD_DOCKER_GROUP" -eq 1 ]; then
  if getent group docker >/dev/null 2>&1; then
    if id -nG "$USERNAME" | tr ' ' '\n' | grep -qx docker; then
      info "'$USERNAME' already in docker group"
    else
      info "adding '$USERNAME' to docker group (root-equivalent -- see README)"
      usermod -aG docker "$USERNAME"
    fi
  else
    info "docker group not present on this host -- skipping"
  fi
fi

# --- 5. Report ----------------------------------------------------------------
info "done. verification:"
id "$USERNAME"
sudo -n -l -U "$USERNAME" || true
