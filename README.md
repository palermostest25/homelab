# Pjaano homelab

Configuration-as-code for the Pjaano lab: three hosts on `192.168.1.0/24`, every
service declared as a file you can re-apply rather than a sequence of SSH
commands someone remembers.

Owner: Warden. Anything in here is expected to satisfy
[`DEPLOY-STANDARD.md`](DEPLOY-STANDARD.md) before it is called done.

## Hosts

| Host | Address | Role | Management surface |
| --- | --- | --- | --- |
| Proxmox VE | 192.168.1.3 | Hypervisor; LXC and VM guests | SSH 22, web UI/API 8006 |
| TrueNAS | 192.168.1.2 | Storage: pools, datasets, SMB/NFS shares, snapshots | SSH 22 (key only), API/UI 443 |
| arcane | 192.168.1.10 | Docker / service host | SSH 22, HTTP 80 |

The lab is **LAN-only**. No router port forwards, no public DNS, no tunnels —
see §8 of the deploy standard. Adding any of those needs the user's explicit
approval recorded in the ticket that adds it.

## Layout

```
DEPLOY-STANDARD.md      the definition of done every change is graded against
README.md               this file
access/                 how agents authenticate to the hosts, sudo scope, recovery
services/<name>/        one directory per deployed service
tools/                  scripts that set up the agent's runner, not a lab host
```

Each `services/<name>/` holds the declarative artifact for that service — a
`docker-compose.yml`, a systemd unit, or a `pvesh`/`midclt` provisioning script —
plus a `README.md` with the eight headings §5 of the standard requires:

> What it is · Host and address · Ports · Start / stop / upgrade (exact commands)
> · Data location · Backup and restore · Healthcheck · Dependencies

See [`services/README.md`](services/README.md) for the template.

## The deploy standard

`DEPLOY-STANDARD.md` at the root of this repo is the single reference. Cite it
from a change ticket as:

```
homelab repo, DEPLOY-STANDARD.md (repo root)
```

It is owned by Sentry and was authored on
PJA-13. **Do not edit it here.** Raise a change on
PJA-13 and let the owner revise it; this copy tracks that
document verbatim.

## Secrets

No credential — password, SSH private key, API token, recovery key — is ever
committed to this repo, written into a README, or pasted into a ticket. Commit
an `.env.example` listing key names only. Real values live in the Paperclip
vault and are referenced by secret name. See [`access/README.md`](access/README.md)
for the per-host secret names.

## Where this repo lives

Canonical working copy: the Paperclip shared project checkout for the Onboarding
project, at `<project checkout root>/homelab`.

Durable remote (live since 2026-09-29): a bare repo on **arcane**
(192.168.1.10) at `/home/paperclip/homelab.git`, branch `main`, remote name
`arcane`:

```
ssh://paperclip@192.168.1.10/home/paperclip/homelab.git
```

Push/pull over SSH as `paperclip` with the `homelab/ssh-key-arcane` Paperclip
secret. LAN-only, so no §8 exposure question.

A **private** GitHub repo remains the intended off-site end state (§8 forbids a
public one
without the user's explicit approval), alongside the arcane remote — GitHub for
durability off-site, arcane for a LAN copy that does not depend on an external
service. It is blocked on the company's GitHub connection: the connection
reports `needs_user_action` ("Review identity and access for this agent"), so
both `git push` and the GitHub tools fail. Tracked on
PJA-15; when the connection is usable, add it as a second
remote and record it here.

Clone:

```
git clone ssh://paperclip@192.168.1.10/home/paperclip/homelab.git
```

Track new remotes on PJA-15.

## Working in this repo

- Commit the artifact, not the transcript. A file you can re-apply beats a
  command you have to remember.
- Every commit message ends with exactly:
  `Co-Authored-By: Paperclip <noreply@paperclip.ing>`
- Update the lab inventory (PJA-12 `inventory` document) in
  the same change that adds or moves a service.

## Runner tooling note

The Paperclip runner image ships no `git` and no `gh`, and the agent account has
no sudo, no `apt` and no `dpkg`. If a heartbeat reports `git: command not found`
or `Paperclip: requested GitHub command is not installed`, run:

```bash
./tools/install-git.sh
```

It is idempotent and safe to run at the top of any heartbeat — see
[`tools/README.md`](tools/README.md), which also covers the
`fatal: empty ident name` failure you hit when committing through the Paperclip
GitHub launcher.
