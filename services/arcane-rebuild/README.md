# Arcane rebuild bundle

**Draft — publication and fresh-host verification pending.** Captured read-only on
2026-09-30: 102 compose definitions, 101 Compose projects, 140 containers, 101
networks and 49 volumes. No host was rebuilt or rebooted to produce this bundle.

## What it is

`tools/rebuild-arcane.sh` is one entrypoint for restoring the committable Arcane
configuration. Default execution prints a plan. `manifest.json` records source
paths, selected projects, volume/network identities, bind prerequisites and input
names. Compose owns its declared named volumes and networks; the observed resource
lists are inventory, not a command to recreate unused or anonymous resources.

96 running non-tunnel stacks are selected by default. Stopped projects and the
untracked `coder` definition remain available via `--stack NAME`. Explicit selection
replaces the default set. Cloudflared, Playit and Twingate are gated by
`--exposure-approval TICKET_URL`; that flag records an existing explicit owner
approval, it does not grant permission. Optional Compose profiles stay disabled.

## Host and address

Source: arcane, 192.168.1.10, Proxmox LXC 102, Debian 12. Run apply only on a fresh,
separately provisioned Debian 12 replacement with equivalent CPU, memory, disk,
network and required devices. Do not assign the production IP while the original
host is online. Proxmox provisioning, passthrough, mount configuration and cutover
are separate operations with their own approvals. The script refuses an unmanaged
Docker host containing containers and refuses to overwrite differing Compose files.

## Ports

The exact port mappings and host-network services are in `stacks/*/compose.yaml`.
Arcane UI uses port 80 on the source host. The script retains those mappings; bind
the replacement only to the private lab network. It changes no router or public DNS.
Do not enable tunnels without approval. Public reverse-proxy certificates and
private proxy configurations are not published in this bundle.

## Start / stop / upgrade

From the repository root, inspect the plan and input names:

```sh
bash tools/rebuild-arcane.sh
bash tools/rebuild-arcane.sh --list-inputs
cp services/arcane-rebuild/.env.example services/arcane-rebuild/.env
chmod 600 services/arcane-rebuild/.env
```

Populate the private file locally using [INPUTS.md](INPUTS.md). Values may also be
provided through process environment variables, which take Compose precedence.
The entrypoint never sources a shell env file and never prints rendered Compose.
Use normal Docker Compose dotenv quoting; preserve dollar signs, multiline values
and original encryption keys. Empty example entries are not usable credentials.
Do not commit the populated file. Per-stack examples contain the corresponding subset.

The private input bundle was proposed to the operator vault as
`homelab/arcane-rebuild-inputs`. Approval and retrieval are separate from the public
bundle. It contains original configuration strings, not just credentials. Restore
application `.env` files separately at the paths recorded in the manifest; do not
replace Invoice Ninja's application `.env` with the rebuild variable file.

After restoring all data and config prerequisites on the replacement host:

```sh
sudo bash tools/rebuild-arcane.sh --check --env-file /root/arcane-rebuild.env
sudo bash tools/rebuild-arcane.sh --apply --data-restored --env-file /root/arcane-rebuild.env
```

`--check` requires Docker Compose already installed. `--apply` can install Docker
from its [official Debian apt repository](https://docs.docker.com/engine/install/debian/)
on fresh Debian 12, validates all selected definitions, enables Docker at boot and
runs `compose up -d --wait` per stack. Existing engines are not upgraded. Conflicting
packages cause an explicit stop. No package removal, volume deletion or pruning is
performed. All exported services retain `always` or `unless-stopped` restart policy.

For an individual stack, retaining the exact original project identity:

```sh
sudo docker compose --env-file /root/arcane-rebuild.env -p STACK -f /opt/docker/stacks/STACK/compose.yaml stop
sudo docker compose --env-file /root/arcane-rebuild.env -p STACK -f /opt/docker/stacks/STACK/compose.yaml up -d --wait
```

For Arcane itself use `-p arcane -f /opt/docker/arcane/compose.yaml`.
Before upgrades, snapshot/backup data, review the image changes and then use the
same command with `pull` followed by `up -d --wait`. Tags are captured as configured,
not pinned digests; a future tag can change. Never use `down -v` as a restore step.

## Data location

Bind data primarily lives under `/opt/docker/appdata`, with Arcane state under
`/opt/docker/arcane/data`; some paths use case-sensitive `/opt/Docker`. Named and
anonymous volume data is held by Docker, ordinarily under `/var/lib/docker/volumes`.
The manifest lists all observed volume names and each stack's bind paths. Declared
named volumes/networks are recreated by Compose under the original project names.
Anonymous volumes and orphan resources cannot be associated reliably from a Compose
file alone: restore them from guest/container-aware backups, not as empty replacements.

## Backup and restore

This is configuration recovery, not an application-data backup. Before cutover,
restore a verified LXC 102/PBS backup or application-consistent exports to a separate
host. Verify the actual backup exists and covers each data path; no backup restore
was tested during this export. Preserve ownership, permissions, database versions,
encryption keys and named volume identities. Supply private bind files and mounts
before running the entrypoint. Missing binds fail before container creation.

Out of scope and private restore sources:

- Application databases, uploads, live container layers, named/anonymous volume
  contents: LXC 102/PBS or application-specific consistent backups. Git has no data.
- Bind config files (Caddyfiles, nginx configuration, Redis config, Prometheus config,
  Gotify topic mapping, application settings): original host backup at the exact
  manifest path. These can contain credentials or private routing. Their public
  reconstruction has not yet been reviewed; missing files block affected stacks.
- Registry authentication at `/root/.docker/config.json`, application `.env` files,
  VPN state and certificates: private vault or host backup; never public git.
- TrueNAS datasets and `/mnt/nas/ARM` data: TrueNAS snapshots/backups and the private
  mount runbook. The older inventory's no-NAS statement is not sufficient evidence
  that this stopped stack's mount dependency is available.
- OS units, root/user crontabs and host-specific scripts: guest backup and existing
  service runbooks. Only system unit/cron filenames were enumerated; contents and
  per-user crontabs still require review. Do not overwrite shared host configuration.
- Proxmox guest config, USB/serial/optical devices, boot order and onboot flag:
  Proxmox backup/config plus inventory, applied by Warden under a separate cutover.

Rollback: leave the original host/data intact, stop the replacement stacks, and
return traffic to the original after checking for writes made on the replacement.
Never roll a database back by merely selecting an older image. A failed apply can
leave earlier stacks running; diagnose privately and rerun after restoring prerequisites.

## Healthcheck

`--check` validates Compose and local prerequisites; it does not test applications.
Apply uses Compose readiness (`up --wait`): healthy for containers with healthchecks,
running for containers without them. This is not proof that every application works.
Inspect selected stacks with `docker compose ... ps`; exercise each documented
application endpoint and retain results in the private task run record. Application
health endpoints are not yet catalogued for every exported stack.

After a real deployment, create a Sentry verification issue with the selected stack
names, target host, endpoints and expected responses. Coordinate the replacement
host reboot and verify services return without an interactive login. This script
never reboots any host. Cold-boot durability remains unproven until that verdict.

## Dependencies

Bring up storage and restore data first, then Docker and Arcane, then the remaining
selected projects in stable alphabetical order. Within a project, Compose honors
its original `depends_on` relationships. Cross-project references in private env
values are not statically resolved: review them and use repeated `--stack` selection
for staged restore if needed. Network DNS, external databases, auth providers,
registry access and private keys must exist before dependent apps can pass checks.

For a fresh target, provision Python 3 and sufficient capacity first. Compare live
free disk/RAM with the source workload and restored data size. No capacity requirement
can be proven from stack counts alone. The script does not alter SSH, sudo, firewall,
existing SMB entries, pool topology or platform versions.
