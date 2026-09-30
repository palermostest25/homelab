# Homelab agent access

How Paperclip agents authenticate to the Pjaano homelab, what they are allowed to
do once in, and how a human gets back in if the vault is unavailable.

Owner: Warden. Source ticket: PJA-11.

> **STATUS: DEPLOYED 2026-09-29.** The `paperclip` account exists on all three
> hosts, each with its own ed25519 key, and key-only login is verified on all
> three. The one deliberate deviation from the original design is that the
> shared human password was **not** rotated — the user declined. See
> [Password rotation](#password-rotation-declined-by-the-user) and
> [Current status](#current-status).

## Hosts

| Host | Address | Role | Management surface |
| --- | --- | --- | --- |
| Proxmox VE | 192.168.1.3 | Hypervisor, LXC/VM guests | SSH 22, web UI/API 8006 |
| TrueNAS | 192.168.1.2 | Storage, datasets, shares | SSH 22 (**key only**), API/UI 443 |
| arcane | 192.168.1.10 | Docker / service host | SSH 22, HTTP 80 |

### Verified SSH auth methods (2026-09-28)

Probed from the Paperclip runner with
`ssh -o PreferredAuthentications=none -o PubkeyAuthentication=no paperclip@<host>`:

```
192.168.1.3   Permission denied (publickey,password).
192.168.1.2   Permission denied (publickey).
192.168.1.10  Permission denied (publickey,password).
```

**TrueNAS accepts publickey only.** A password cannot bootstrap 192.168.1.2 over
SSH at all; that host must be bootstrapped through the HTTPS middleware API,
which is the durable path anyway. This is why `bootstrap-truenas-user.sh` is a
separate script from the systemd-host one.

Bootstrap used `root` over SSH on 192.168.1.3 and 192.168.1.10, and `root` over
the HTTPS middleware API on 192.168.1.2. `denby` was rejected by sshd on both
Linux hosts (`Permission denied`), so it is not a usable bootstrap path.

## Accounts

As deployed, 2026-09-29:

| Host | Account | uid | Home | Auth | Purpose |
| --- | --- | --- | --- | --- | --- |
| 192.168.1.3 (Debian 13, PVE 9.2.2) | `paperclip` | 1000 | `/home/paperclip` | ed25519 key only, password locked | Agent service account |
| 192.168.1.2 (TrueNAS 25.10.0.1) | `paperclip` | 3006 | `/mnt/Apps/paperclip` | ed25519 key only, `password_disabled: true` | Agent service account |
| 192.168.1.10 (Debian 12) | `paperclip` | 1000 | `/home/paperclip` | ed25519 key only, password locked | Agent service account |
| all three | `root`, `admin`, `denby` | — | — | human interactive, unchanged | Pre-existing human accounts |

The `paperclip` account never has a password. It is key-only by construction,
not key-only by convention — `passwd --lock` on the Linux hosts and
`password_disabled: true` on TrueNAS. On arcane it is additionally in the
`docker` group (gid 996); see [Sudo scope](#sudo-scope) for why that is the one
genuinely root-equivalent grant in this design.

### Why the TrueNAS home is on a pool and not `/home`

TrueNAS refuses to set `sshpubkey` on a user whose home directory is not
writable:

```
{"user_create.sshpubkey": [{"message": "The home directory is not writable. Leave this field blank.", "errno": 22}]}
```

The middleware writes `authorized_keys` into the user's home, and the default
(`/var/empty`) is read-only — which is exactly why every other non-builtin user
on that box has `sshpubkey: false`. The account was therefore created with
`home: /mnt/Apps` and `home_create: true`, giving `/mnt/Apps/paperclip` at mode
`0700`. A directory in a pool root, not a new dataset: nothing to snapshot, and
removing the user removes it.

## Keys and secret names

One keypair **per host**, not one key across the lab, so compromising one host
does not yield the other two.

| Host | Paperclip secret holding the private key | Access binding | Public key lives at |
| --- | --- | --- | --- |
| 192.168.1.3 | `homelab/ssh-key-proxmox` | `access.HOMELAB_SSH_KEY_PROXMOX` | `/home/paperclip/.ssh/authorized_keys` |
| 192.168.1.2 | `homelab/ssh-key-truenas` | `access.HOMELAB_SSH_KEY_TRUENAS` | user object `sshpubkey` field (middleware-managed) |
| 192.168.1.10 | `homelab/ssh-key-arcane` | `access.HOMELAB_SSH_KEY_ARCANE` | `/home/paperclip/.ssh/authorized_keys` |

Installed public key fingerprints — safe to publish, and the thing to compare
against if you ever want to confirm the key on a host is the key in the vault
(`ssh-keygen -lf /home/paperclip/.ssh/authorized_keys`):

```
256 SHA256:z2TaKocKAZYM+0rmTd7quvbhP/rNg+CXC1mgmysEWDs paperclip@proxmox (ED25519)
256 SHA256:B47MnPE8JJZYfQvs+yJt9a17zgOpiA/YhuppOeGbNPA paperclip@truenas (ED25519)
256 SHA256:tw7gxIM5MSUCH9mRnve2gXdjH3IOLT3ESg6z5fTspJw paperclip@arcane (ED25519)
```

Private keys exist **only** in the Paperclip vault. They are not in this repo,
not in any issue comment, not in any task description, and not on the runner
between heartbeats. Each key is generated ed25519 with no passphrase, because
the vault — not a passphrase — is the thing protecting it.

The bindings are `access.*` rather than `env.*` on purpose: an `env.*` binding
would inject the private key into the environment of every child process the
adapter spawns. `access.*` means an agent fetches the key on demand, writes it
to a `0600` file under the run scratch directory, and the runtime deletes that
directory when the run ends.

## Password rotation (declined by the user)

Step 6 of PJA-11 called for rotating the shared password on
`root`, `admin` and `denby` across all three hosts. **The user explicitly
declined**, answering on the ticket: *"DO NOT ROTATE MY PASSWORDS, just use them,
or if you must, install your ssh keys, do not change the password."*

That decision is recorded here rather than silently dropped, because it leaves a
real residual risk:

- The shared password is still live on `root`, `admin` and `denby` on all three
  hosts, and it is still reused across every one of those accounts.
- It is still in plaintext in the PJA-1 interaction history,
  so anyone with read access to this Paperclip company can read it.

What the key work does change: **no agent depends on that password any more.**
Agent access is now per-host keys, so rotating it later is a decision about human
credential hygiene alone — it will not break any agent. `homelab/<host>-<account>-password`
is reserved as the naming scheme if the user changes their mind.

## Sudo scope

Drop-ins live in `access/sudoers.d/` and are installed to `/etc/sudoers.d/paperclip`
at mode 0440, validated with `visudo -c` **before** being moved into place. A
malformed drop-in breaks sudo for every user on the host, so the bootstrap script
stages and validates first and aborts without touching the host if validation fails.

This is **not** a blanket `ALL=(ALL) NOPASSWD: ALL` grant on any host.

### Proxmox (192.168.1.3) — `access/sudoers.d/paperclip-proxmox`

| Granted | Why |
| --- | --- |
| `systemctl` start/stop/restart/reload/enable/disable/daemon-reload | Deploying and running services is the job |
| `systemctl --no-pager status/list-units`, `is-active`, `is-enabled` | Proving a service actually runs |
| `journalctl --no-pager` | Debugging a failed deploy |
| `pct` / `qm` — enumerated subcommands only | Guest provisioning and lifecycle |
| `zpool list/status`, `zfs list/get`, `pvesm status/list`, `pveversion` | Capacity headroom checks before provisioning |
| `du` under `/var/lib/vz` **(proposed, PJA-27)** | `/var/lib/vz/images/<vmid>/` is `root:root 0700`; without this a capacity report for `local` is a guess |
| `pvesm free local:iso/*`, `local:vztmpl/*` **(proposed, PJA-27)** | Reclaiming stale ISOs and templates |
| `apt-get clean` **(proposed, PJA-27)** | 3.2 G of apt cache on a 92%-full `local` |
| `rm -rf /var/tmp/vzdumptmp*`, `/var/tmp/.guestfs-0` **(proposed, PJA-27)** | Root-owned orphans with no Proxmox-native removal verb |

The four rows marked *proposed* are in the tracked drop-in but **not yet
installed on the host** — installing them needs root, which no agent has. See
PJA-27.

The reclaim grants are built so they cannot reach a guest disk. A sudoers `*`
does not match `/`, so `local:iso/*` stops at one path segment after `iso/` and
`local:132/vm-132-disk-0.qcow2` is unreachable by construction rather than by
convention. The same property bounds `rm -rf /var/tmp/vzdumptmp*` to that one
prefix. `rm` in a sudoers file is still the sharpest edge in the drop-in; it is
there only because orphaned vzdump temp dirs are root-owned and Proxmox has no
verb that removes them. Dropping `PC_RECLAIM_TMP` costs ~1 G and is a reasonable
trade if that edge is unwanted.

Deliberately withheld, and why:

- **`pct destroy` / `qm destroy`.** Subcommands are enumerated individually
  rather than wildcarding the binary, so guest deletion is simply not reachable.
  Destroying a guest needs explicit go-ahead in a ticket, so it should not be a
  standing grant.
- **`zfs destroy`, `zpool` write verbs.** Same reasoning — data loss.
- **`pvesm free` on a guest-disk volid.** Only the `iso/` and `vztmpl/` prefixes
  are granted. Freeing an orphaned guest volume — such as the `vm-171-*` set
  found in PJA-27 — stays a human decision.
- **Package installation.** `apt-get clean` is granted; nothing else is.
  `clean` only empties `/var/cache/apt/archives` and can neither fetch nor unpack,
  so it does not carry the usual `apt-get` escalation (maintainer scripts run as
  root). `apt-get install`/`remove`/`upgrade` remain unreachable.
- **Paged `systemctl status` / bare `journalctl`.** `--no-pager` is required on
  every read verb. The default pager is `less`, which has a shell escape (`!sh`);
  without `--no-pager` a read-only grant becomes an interactive root shell. This
  is the single most important detail in these files.

### arcane (192.168.1.10) — `access/sudoers.d/paperclip-arcane`

Same systemd and journal grants, plus read-only `df`/`free`/`du`.

**Docker is the honest exception.** `paperclip` is added to the `docker` group
rather than given a sudo rule, and either way that is **root-equivalent**: anyone
who can reach the Docker socket can run `docker run -v /:/host` and own the box.
There is no way to narrow this while still allowing compose stacks to be
deployed, so it is stated plainly rather than presented as constrained. If that
is unacceptable, the alternative is rootless Docker or Podman for this account —
a larger change that belongs on its own ticket.

### TrueNAS (192.168.1.2)

**No sudo granted.** TrueNAS regenerates sudo configuration from the user object
in its config database, so `/etc/sudoers.d` is the wrong mechanism there — a file
dropped in by hand does not survive. Scoped sudo, if it is ever genuinely needed,
is expressed through the user's `sudo_commands_nopasswd` field via the API.

For now the account does dataset, share, and snapshot work through the middleware
API under its own privileges, which is both narrower and upgrade-safe. Grant sudo
only when a specific task proves it necessary, and record the reason here.

## Human recovery path

**If the Paperclip vault is unavailable, agent access is gone — human access is
not.** Nothing here touches how a person logs in.

1. **Proxmox web UI** — https://192.168.1.3:8006 with `root` (PAM realm). Unaffected
   by agent key work.
2. **TrueNAS UI** — https://192.168.1.2 with `root`/`admin`. Unaffected.
3. **Physical/IPMI console** on either host, then `root` at the local console.
4. **Revoking agent access entirely**, if an agent key is ever suspected
   compromised — as `root` on each host:
   ```bash
   # Proxmox / arcane
   rm -f /home/paperclip/.ssh/authorized_keys
   rm -f /etc/sudoers.d/paperclip
   visudo -c                      # confirm sudoers is still valid afterwards
   usermod --lock --expiredate 1 paperclip
   ```
   ```bash
   # TrueNAS -- through the API, so the change survives an upgrade.
   # Clearing sshpubkey revokes the key but keeps the account; deleting the
   # user also removes its home at /mnt/Apps/paperclip.
   # (UI: Credentials -> Local Users -> paperclip -> Edit, clear "Authorized Keys")
   curl -sk -u root -X PUT https://192.168.1.2/api/v2.0/user/id/78 \
     -H 'Content-Type: application/json' -d '{"sshpubkey": null}'
   ```
   Removing the key locks the agents out immediately. It does not affect `root`,
   `admin`, or `denby`.
5. **The `paperclip` account is never the only way into anything.** If it is ever
   the sole path to a service, that is a bug in the service's deployment, not a
   recovery procedure.

Because the `paperclip` account has no password, there is no agent credential a
human needs in order to recover — deleting the key is sufficient and complete.

## Re-running the bootstrap

Both scripts are idempotent; running them twice is safe and is the intended way
to reconcile drift.

```bash
# Proxmox (192.168.1.3) -- as root on the host
./bootstrap-paperclip-user.sh \
  --pubkey 'ssh-ed25519 AAAA... paperclip@proxmox' \
  --sudoers ./sudoers.d/paperclip-proxmox

# arcane (192.168.1.10) -- as root on the host
./bootstrap-paperclip-user.sh \
  --pubkey 'ssh-ed25519 AAAA... paperclip@arcane' \
  --sudoers ./sudoers.d/paperclip-arcane \
  --docker-group

# TrueNAS (192.168.1.2) -- from anywhere with API reach.
# TRUENAS_API_KEY, or TRUENAS_USER + TRUENAS_PASSWORD for a human account.
TRUENAS_API_KEY=... ./bootstrap-truenas-user.sh \
  --pubkey 'ssh-ed25519 AAAA... paperclip@truenas'
```

All three were re-run on 2026-09-29 against the already-configured hosts and
reported no-ops rather than duplicating anything:

```
==> user 'paperclip' already exists -- leaving as is
==> public key already present in authorized_keys -- not re-adding
==> 'paperclip' already in docker group
==> user 'paperclip' exists (id 78) -- updating in place
```

Verification, per host:

```bash
ssh -i <key> -o PasswordAuthentication=no paperclip@<host> 'id; sudo -n -l'
```

## How an agent uses this in a heartbeat

The private key is not on the runner between heartbeats. Fetch it, use it, let
the runtime delete it:

```bash
PAPERCLIP_API_BASE="${PAPERCLIP_API_URL%/}"; PAPERCLIP_API_BASE="${PAPERCLIP_API_BASE%/api}"
umask 077
# NOTE: the fetch route is /api/agents/me/secrets/:key/value where :key is the
# SHORT key (e.g. ssh-key-proxmox), not the full secret name. Sending the full
# name (even %2F-encoded) returns 403 "Secret access is not granted", which is
# easy to misread as a missing binding. Use `GET /api/agents/me/secrets` to see
# the short keys you hold.
curl -s -X POST -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
  "$PAPERCLIP_API_BASE/api/agents/me/secrets/ssh-key-proxmox/value" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['value'], end='')" \
  > "$PAPERCLIP_RUN_SCRATCH_DIR/id_proxmox"
chmod 600 "$PAPERCLIP_RUN_SCRATCH_DIR/id_proxmox"

ssh -i "$PAPERCLIP_RUN_SCRATCH_DIR/id_proxmox" \
    -o PasswordAuthentication=no -o IdentitiesOnly=yes \
    paperclip@192.168.1.3 'pct list'
```

Verified 2026-09-29: with the short key the call returns the vaulted value
(HTTP 200). A nonexistent or unbound key returns 403, so this endpoint
deliberately does not distinguish "not granted" from "does not exist" —
use `GET /api/agents/me/secrets` to see what you actually hold. Note the git/ssh
corollary: the runner's PATH fronts `git` with a Paperclip launcher shim that
strips `GIT_SSH_COMMAND`, so `git ls-remote arcane` fails even with a good key —
call the real binary (`/home/paperclip/.local/bin/git`, see `tools/README.md`)
with `GIT_SSH_COMMAND` pointing at the fetched key.

## Reboot verification

`access/reboot-verify.sh` runs the per-host post-reboot check end to end: fetches
each key, SSHes in on the key alone, and asserts the expected uid (1000 / 3006 /
1000) plus the host check. It is read-only and reboots nothing.

It separates three outcomes rather than collapsing them into pass/fail:

| Outcome | Meaning |
| --- | --- |
| `PASS` | Key worked **and** the host booted after the key was deployed — genuinely reboot-verified. |
| `PASS-LIVE` | Key worked, but the host has not rebooted since deploy. Proves access, proves nothing about reboot survival. |
| `FAIL` | Connected but a criterion did not hold, or SSH was refused. |
| `BLOCKED` | The key could not be read (no approved `access.*` binding). Missing evidence, not a broken host. |

Exit status: `0` all good, `1` a real failure, `3` blocked on a grant — so a
routine can alert on it.

Write it under `$PAPERCLIP_RUN_SCRATCH_DIR`, never the workspace — the workspace
is a git checkout shared between agents, the run scratch directory is neither and
is removed when the run ends.

## Reclaiming space on Proxmox `local`

`access/reclaim-proxmox-local.sh` reclaims space on the `local` dir storage on
192.168.1.3. It fetches the key the same way `reboot-verify.sh` does, and it is
**dry-run by default** — pass `--apply` to actually delete.

```bash
access/reclaim-proxmox-local.sh            # report what it would free
access/reclaim-proxmox-local.sh --apply    # free it
```

It touches only logs, caches, orphaned `/var/tmp` dirs, and ISO/template volumes
that **no `qm config` references**. It re-derives that reference list live on
every run rather than trusting a checked-in list, so an ISO attached to a guest
since the last run is skipped, not deleted. It never touches a guest disk.

Idempotent: every step reports `OK` / `SKIP` / `BLOCKED` and a second run is a
no-op that still prints an accurate before/after. `BLOCKED` means the sudo rule
is not installed on the host — which is the current state of everything except
the journal vacuum, see PJA-27.

Exit status: `0` reclaimed and `local` is under 80%, `1` reclaimed but still
above 80%, `3` blocked on the key grant. The `1` is deliberate — the safe set
does not add up to the target, so a green exit would misreport the host as fixed
while guest disks are still the real problem.

## Current status

**Deployed and verified on all three hosts, 2026-09-29.**

| Item | State |
| --- | --- |
| `paperclip` account on .3 / .2 / .10 | done |
| Per-host ed25519 keys installed | done |
| Key-only SSH verified per host | done |
| Per-host key isolation verified | done — each key is rejected by the other two hosts |
| Scoped sudo, `visudo -c` validated | done on .3 and .10; deliberately none on .2 |
| Private keys filed as Paperclip secret proposals | done — **pending user approval** |
| Shared password rotated | **not done — the user declined.** See [Password rotation](#password-rotation-declined-by-the-user) |

The three secrets and their `access.*` bindings are proposals, not grants. Until
the user approves **both** the secret and its binding, no agent can read these
keys back. Approving the secret alone is not enough — without the binding the
name is visible but the value is not.

Runner tooling: `git` and `gh` are present via the Paperclip GitHub runtime shim,
but the managed GitHub identity is incomplete (`GitHub access unavailable: The
managed GitHub identity is incomplete`), so this repo still has no remote and
nothing is pushed. Tracked on PJA-15.
