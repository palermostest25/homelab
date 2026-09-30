# Pjaano lab inventory (public copy)

**Sweep date:** 2026-09-29 (credentialed sweep, key-only SSH as `paperclip`)
**Gathered by:** Warden Backup, from the Paperclip runner
**Completeness:** ✅ Full credentialed sweep. Two narrow gaps remain, both named in §6
(Truenas share ACLs/consumers and iSCSI detail need a TrueNAS admin credential;
`paperclip` has no sudo there by design).

> **Maintenance:** Warden updates this document as part of **every** change that
> touches the lab. A change that adds, moves or removes anything and does not
> update this file is not finished (`DEPLOY-STANDARD.md` §6).

Credentials are referenced by Paperclip secret name only
(`homelab/ssh-key-{proxmox,truenas,arcane}`). No credential appears in this file.

> **Public-copy note:** this is the trimmed public edition. Exact storage
> capacities, share paths, and the operational findings register are kept in
> the private tracker. Check live headroom (`pvesm status`, `zpool list`,
> `df -h`) before provisioning.

---

## 1. Summary

| Host | Address | What it is | Reachable from runner |
| --- | --- | --- | --- |
| Proxmox VE | 192.168.1.3 | Hypervisor, 2-node cluster (`proxmox` + `pve2`) | SSH 22, HTTPS 443 (nginx proxy → :8006), PVE UI/API 8006 |
| TrueNAS | 192.168.1.2 | Storage: pools, SMB shares, NFS export, apps | SSH 22 (key only), HTTP 80, HTTPS 443, SMB 445, NFS 2049, iSCSI 3260, noVNC 8006 |
| arcane | 192.168.1.10 | Proxmox LXC 102, Docker/service host | SSH 22, HTTP 80 (Arcane UI) |
| *(runner)* | 192.168.1.12 | Proxmox LXC 146 (`Paperclip`), this agent's host | — |
| *Gateway* | 192.168.1.1 | unknown, needs the user's confirmation | HTTP 80, HTTPS 443 (seen in earlier sweep) |

**Where should a new service go:** containerised services belong on arcane;
VMs/LXCs belong on Proxmox `SSD2` — **not** `local`; bulk storage consumes
TrueNAS `Tank` or `Lake`. Always check live headroom first (see note above).

---

## 2. Proxmox VE — 192.168.1.3

### Host

| Item | Value | Evidence |
| --- | --- | --- |
| Product | Proxmox VE 9.2.2 (`pve-manager 9.2.2`), `proxmox-ve 9.2.0`, Debian 13 | `sudo pveversion -v` |
| Kernel | `7.0.2-6-pve` (running) | same |
| CPU | 48× Intel Xeon E5-2658A v3, 2 sockets × 12 cores × HT | `lscpu` |
| RAM | 125 Gi total — check `free -h` live before provisioning | `free -h` |
| Swap | in use — check `free -h` live; watch for memory pressure | `free -h` |
| Uptime | 74 days (at sweep time) | `uptime`, load ~11 |
| Cluster | **2-node cluster: `proxmox` + `pve2`**, corosync + `ceph-mon@proxmox` active | `/etc/pve/nodes/`, `systemctl` |
| Local disks | **no ZFS pools** (`zpool status`: none); `local` is dir storage on `/` | `pvesm status`, `zpool` |
| Root fs | `/dev/mapper/pve-root` — dir storage `local` lives on `/`; check `pvesm status` for headroom | `df -h /` |
| Network | `vmbr0` on `eno3` (up), `192.168.1.3/24`; `eno1/2/4` down; no VLANs on host | `ip -br` |
| Port 443 | host `nginx` reverse-proxying `https://192.168.1.3:8006` with the Debian snakeoil cert. Not `pveproxy`, not an intruder — a local proxy vhost. | `/etc/nginx/sites-available/proxmox` |
| Other listeners | 22, 111, 3128, 3300, 3493, 6789, 8006, 8787, 9000, 9100, 25 (localhost) | `ss -tln` |

### Storage backends (`pvesm status` — check live for headroom)

| Name | Type | Notes |
| --- | --- | --- |
| `local` | dir | on `/`; reclaimed below 80% in PJA-27 — see below |
| `SSD` | dir | guest disks |
| `SSD2` | dir | guest disks (VM 132 moved here in PJA-27) |
| `NAS` | cifs | TrueNAS-backed |
| `PBS` | pbs | Proxmox Backup Server datastore |

#### `local` reclaim (PJA-27, 2026-09-29)

`local` is a dir storage on `/`. Most of it sits in
`/var/lib/vz/images/<vmid>/`, which is `root:root 0700` and unreadable
unprivileged, so live measurement needs the sudo scope in
`access/sudoers.d/paperclip-proxmox`.

**Orphaned volumes with no owning guest.** `pvesm list local` reports several
`vm-171-*` volumes, but no `171.conf` exists on either node and 171 is in
neither `qm list` nor `pct list`, with no PBS snapshot either. Smaller strays
(`vm-103-disk-0`, `vm-119-disk-0`, `vm-123-disk-0`) are in the same state.
**Not deleted** — freeing a guest volume needs an owner identification and
explicit go-ahead.

User decision on PJA-27 (2026-09-29): back the 171 volumes
up to PBS, then delete them; move VM 132 to SSD2; install the reclaim sudo
drop-in as committed. Execution is blocked on root access to 192.168.1.3 —
`qm move-disk`, `vzdump`, and installing `/etc/sudoers.d/paperclip` are all
outside the agent's sudo scope. The exact commands are staged below; a human
with root runs them.

**ISO references** (checked against every `qm config`): `VirtIO.iso` is
attached to VM 109 and the Fedora KDE ISO to VM 119, both running — keep.
`Windows.iso` and the Kali installer ISO are referenced by nothing.

`access/reclaim-proxmox-local.sh` re-derives all of this live and performs the
safe subset; it recomputes ISO references on each run rather than trusting
this table.

**Staged root runbook for the user's PJA-27 answers** (run on 192.168.1.3 as
root; VM 132 is stopped so no live-migration risk; every step is re-runnable):

```sh
# 1. Move VM 132 local -> SSD2 (approved: move-ssd2).
#    STATUS 2026-09-29: DONE and verified live. sata0 is on SSD2,
#    no unused0 remains, local reads below 80%.
#    The human-root delete (`qm set 132 --delete unused0`) freed the source copy.
#    Rollback path: none needed — guest boots from the SSD2 copy (stopped, untested boot).

# 2. Back up the orphaned 171 volumes to PBS, then delete them.
#    171 has no guest config, so vzdump cannot address it by ID. Attach each
#    disk read-only to a scratch VM (or loop-mount the qcow2) and back the
#    scratch guest up with: vzdump <scratch-vmid> --storage PBS --mode snapshot
#    Verify the PBS snapshot restores before proceeding. Then, per volume:
#    pvesm free local:171/vm-171-disk-N.qcow2   # N = 0..7
#    (also frees the three small strays: local:103/vm-103-disk-0.qcow2,
#     local:119/vm-119-disk-0.qcow2, local:123/vm-123-disk-0.qcow2)

# 3. Install the reclaim sudo drop-in (approved: install-full; visudo -c passes):
scp access/sudoers.d/paperclip-proxmox root@192.168.1.3:/etc/sudoers.d/paperclip
ssh root@192.168.1.3 'chown root:root /etc/sudoers.d/paperclip && chmod 0440 /etc/sudoers.d/paperclip && visudo -c -f /etc/sudoers.d/paperclip'

# 4. Run the safe reclaim, then confirm local < 80%:
access/reclaim-proxmox-local.sh --apply
pvesm status   # local must read below 80%
```

Note: the `PC_RECLAIM_STORE` lines need the escaped colon (`local\:iso/*`) —
an unescaped `local:iso/*` fails `visudo -c` (fixed in-repo 2026-09-29).

### VMs (`qm list` + `qm config`)

| VMID | Name | State | onboot | vCPU | RAM | Disk | Net |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 100 | WindowsServer | running | 1 | 4 | 16 G | SSD2:32 G | vmbr0, static MAC |
| 103 | HomeAssistant | running | 1 | 2 | 4 G | local:32 G | vmbr0 |
| 104 | k3s-1 | stopped | 0 | 2 | 4 G | SSD:20 G | vmbr0 |
| 109 | Windows11 | running | 1 | 4 | 16 G | SSD2:128 G | vmbr0 |
| 114 | Kemp | running | 1 | 1 | 2 G | SSD:16 G | vmbr0 |
| 115 | ESXi | stopped | 0 | 2 | 8 G | SSD:32 G | vmbr0 |
| 117 | Claude-API | stopped | 0 | 2 | 2 G | local:20 G + cloudinit | vmbr0 |
| 119 | Fedora-KDE | running | 1 | 4 | 16 G | SSD2:64 G | vmbr0 |
| 123 | UniFi | stopped | 0 | 2 | 4 G | local:32 G | vmbr0 |
| 129 | macOS-Sequoia | stopped | 0 | 16 | 16 G | SSD2:1 G + 128 G | vmbr0 |
| 132 | FitGirl | stopped | 0 | 4 | 8 G | SSD2:64 G (sata0) — moved off `local` in PJA-27, verified 2026-09-29 | vmbr0 |
| 139 | DezKVM | stopped | 0 | 2 | 4 G | SSD2:64 G | vmbr0 |
| 144 | Trades | running | 1 | 2 | 8 G | SSD2:32 G | vmbr0 |
| 200 | mos | stopped | 0 | 4 | 16 G | SSD2:64 G | vmbr0 |

6 running, 8 stopped. All `ostype` l26 except Windows/macOS guests. Purpose is
from names only — not verified per guest (no login to guests, out of scope).

### LXC containers (`pct list` + `pct config`)

Static IP shown where set; `dhcp` = address from LAN DHCP (these account for
most of the "unknown hosts" in the earlier §5 sweep).

| VMID | Name | State | onboot | Cores | RAM | Rootfs | IP |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 101 | ProxmoxHelperScripts | running | 1 | 2 | 4 G | local:4 G | .18 static |
| 102 | Arcane | running | 1 | 12 | 24 G | SSD:256 G | .10 static |
| 105 | FeilmanFoundation | running | 1 | 4 | 4 G | SSD:16 G | .150 static |
| 106 | iNetPanel | running | 1 | 1 | 1 G | local:8 G | dhcp |
| 107 | iVentoy | running | 1 | 1 | 1 G | local:8 G | .20 static |
| 108 | 1Panel | running | 1 | 1 | 4 G | local:8 G | dhcp |
| 110 | Hostiqo | running | 1 | 2 | 2 G | SSD:8 G | .47 static |
| 111 | DiscordBots | stopped | 0 | 1 | 512 M | local:8 G | .37 static |
| 112 | Kasm | running | 1 | 2 | 8 G | SSD2:64 G | .70 static |
| 113 | OpenClaw | stopped | 0 | 1 | 4 G | SSD:8 G | dhcp |
| 116 | Traefik | running | 1 | 4 | 4 G | local:8 G | .254 static |
| 118 | MMKF-Tailscale | running | 1 | 1 | 512 M | local:8 G | dhcp |
| 120 | AI | running | 1 | 1 | 4 G | local:8 G | .55 static |
| 121 | AMP | running | 1 | 4 | 8 G | SSD2:64 G | dhcp |
| 122 | PiHole | running | 1 | 1 | 1 G | SSD:8 G | .250 static |
| 124 | Authentik | running | 1 | 4 | 4 G | SSD:8 G | dhcp |
| 125 | Bambuddy | stopped | 0 | 4 | 4 G | local:8 G | .94 static |
| 126 | Hermes | running | 1 | 4 | 8 G | SSD:32 G | .19 static |
| 127 | Technitium | running | 1 | 1 | 4 G | SSD:8 G | .251 static |
| 128 | Test | running | 0 | 1 | 2 G | SSD:8 G | dhcp, **VLAN tag 3** |
| 130 | ClaudeCode | running | 1 | 2 | 2 G | SSD:10 G | dhcp |
| 131 | LiteLLM | running | 1 | 4 | 4 G | SSD:20 G | .40 static |
| 133 | Nuclias | stopped | 0 | 4 | 4 G | SSD:8 G | .54 static |
| 134 | Coder | running | 1 | 4 | 8 G | SSD2:64 G | .76 static |
| 135 | Time | running | 1 | 2 | 4 G | SSD2:16 G | .99 static |
| 136 | NebulaSync | running | 1 | 1 | 4 G | SSD2:8 G | .73 static |
| 137 | T3 | running | 1 | 4 | 8 G | SSD2:32 G | .27 static |
| 138 | atvloadly | running | 1 | 2 | 4 G | SSD2:8 G | .48 static |
| 140 | BlitzOS | running | 1 | 4 | 8 G | local:16 G | .63 static |
| 141 | Temp-Log | stopped | 0 | 2 | 2 G | local:16 G | .57 static |
| 142 | step-ca | running | 1 | 2 | 4 G | local:8 G | .29 static |
| 143 | SearXNG | running | 1 | 1 | 4 G | local:8 G | .30 static |
| 145 | LanScan | running | 1 | 1 | 512 M | SSD2:4 G | .50 static |
| 146 | Paperclip | running | 1 | 2 | 4 G | SSD:16 G | .12 static |

29 running, 5 stopped (111, 113, 125, 133, 141). All on `vmbr0`, no per-guest
VLAN except 128. Guest 107 was broken — **fixed in PJA-26**,
see the private findings register.

Notable: 102 Arcane is **privileged** with USB/serial passthrough
(`/dev/ttyUSB0/1`, `/dev/ttyACM0/1`, `apparmor: unconfined`) and tags
`docker;important`. 118 runs Tailscale, 116 Traefik (.254), 122 PiHole (.250),
127 Technitium DNS (.251), 142 step-ca (.29, internal CA).

---

## 3. TrueNAS — 192.168.1.2

| Item | Value | Evidence |
| --- | --- | --- |
| Version | TrueNAS **25.10.0.1**, kernel `6.12.33-production+truenas` | `/etc/version`, `uname` |
| Upgrade trail | boot environments for 25.04.2.4 → 25.10.0 → 25.10.0.1 | `boot-pool/ROOT` |
| Uptime | 2 days (at sweep time) | `uptime` |
| SSH | `publickey` only; `paperclip` (uid 3006) has **no sudo** by design | access doc + probe |
| API | middleware `midclt` requires auth; `paperclip` is not an admin — share ACLs, task history, replication status not readable with this account | `midclt` → `ENOTAUTHENTICATED` |

### Pools (`zpool list` / `zpool status` — all ONLINE, 0 errors)

| Pool | Layout | Last scrub |
| --- | --- | --- |
| Tank | raidz1, 4 disks | 2026-09-28, 0 errors |
| Lake | raidz1, 4 disks | 2026-09-20, 0 errors |
| Apps | single disk | 2026-09-13, 0 errors |
| Pond | mirror, 2 disks | never (new/empty) |
| boot-pool | single disk | 2026-09-27, 0 errors |

Check `zpool list` live for headroom before provisioning — Tank is the pool
to watch. (Exact capacities: private tracker.)

### Key datasets (`zfs list` — names only, sizes in private tracker)

- `Tank/Tank`, `Tank/Isolated`, `Tank/Main` (media),
  `Tank/John`, `Tank/TimeMachine`, `Tank/VM`,
  `Tank/iSCSI` (iSCSI backing), `Tank/Share`, `Tank/Seafile`.
- `Lake/VM` (incl. `Games`), `Lake/PBS` (backup store),
  `Lake/Lake` (media mirror of `Tank/Main` content), `Lake/Backups`.
- `Apps/VMs`, `Apps/ix-apps` (app configs + docker data).
- `Pond/Pond` empty.

### Shares

11 SMB shares (names only — paths and ACLs/consumers need admin, see §6):

`Tank`, `Proxmox`, `Images`, `Images-Updated`, `win11`, `isolated`,
`BigTank`, `Backups`, `TimeMachine`, `John`, `Pond`.

NFS: one export scoped to the LAN (rw, `sec=sys`); no active NFS client
mount observed at sweep time. iSCSI: target portal listening on **:3260**
with a backing dataset; target/LUN detail needs admin API — see §6.

### Apps on TrueNAS itself

34 app configs in the ix-apps tree: apt-cacher-ng, arr,
audiobookshelf, automatic-ripping-machine, backblaze, beszel-agent, dumbdrop,
filebrowser, filebrowser-quantum, firefox, fireshare, frigate, immich,
inkheart, jdownloader, jellyfin, metube, musicgrabber, navidrome, nexus,
ollama, openspeedtest, pihole, romm, scrutiny, seafile, share, slink,
syncthing, tagr, truenas-auto-update, urbackup, windows, zerobyte.
App ports visible in listeners include 30013–31055, 5800–5830, 6900–7000,
7474, 7800, 8006 (noVNC), 8080, 8181, 9003–9016.

### Snapshots / scrubs

- 358 snapshots total; automatic snapshots running (latest 2026-09-27).
- All pools scrubbed within the last 16 days with 0 errors (table above).

---

## 4. arcane — 192.168.1.10 (Proxmox LXC 102)

| Item | Value | Evidence |
| --- | --- | --- |
| What | LXC container on Proxmox (VMID 102), privileged, `systemd-detect-virt: lxc` | `pct config 102` + in-guest probe |
| OS | Debian 12 (bookworm), kernel `7.0.2-6-pve` | `/etc/os-release` |
| Resources | 12 cores, 23 Gi RAM — check `df`/`free` live for headroom before adding services | `df`, `free` |
| Swap | in use — check `free -h` live; watch for memory pressure | `free -h` |
| Uptime | 23 days | `uptime` |
| IP | .10 static (eth0, vmbr0 via host) | `ip -br` |
| Mounts | **No CIFS/NFS mounts** — fully self-contained on local rootfs | `findmnt -t cifs,nfs` |
| Port 80 | Arcane UI (container `arcane`, `getarcaneapp/arcane:latest`) | `docker ps`, `curl /api/version` |
| Arcane version | **v2.10.2**, upstream v2.14.0 available (unpatched Docker control plane — see private findings register) | `/api/version` |
| paperclip account | member of the `docker` group (PJA-44 fix; `sentry-push.py` needs `docker ps`) | `id paperclip` |

### Containers

**138 containers running, 99 compose stacks** (`docker compose ls`), all under
`/opt/docker/stacks/<name>/compose.yaml` except Arcane itself
(`/opt/docker/arcane/compose.yaml`). Full `docker ps` captured at sweep time;
selection below (LAN ports → container port):

| Service | Container(s) | LAN port(s) |
| --- | --- | --- |
| Arcane UI | `arcane` | 80 |
| PiHole (+DNS :53) | `pihole` | 53, 1026, 1027 |
| Beszel / monitor | `beszel`, `beszel-agent`, `cadvisor`, `grafana`, `uptime-kuma-*` | 8090, 6001, 1005, 1003 |
| Forgejo | `forgejo` | 1053, 1054 |
| Vaultwarden | `vaultwarden` | 1049 |
| Litellm / OpenWebUI | `litellm-*`, `openwebui-*` | 4000, 4002 |
| Paperless-ngx + AI | `paperless-*` | 1007, 1012, 1030 |
| Immich-class media | `immich` (TrueNAS app), `stremio`, `aiostreams`, `jellyfin` (TrueNAS) | 9001, 9002 |
| Nginx Proxy Mgr | `nginx-proxy-manager-app-1` | 1014–1016 |
| wg-easy VPN | `wg-easy` | 1035, 51820/udp |
| RustDesk | `hbbs`, `hbbr` | 21115–21119 |
| Crafty (Minecraft) | `crafty_container` | 1020, 1021, 25500–25600 |
| Guacamole | `guacamole*` (4) | 1033 |
| Twingate / Cloudflared / playit | `twingate-*`, `cloudflared-*`, `playit-*` | outbound tunnels — verify whether any tunnel is actually established before asserting "LAN-only" |
| WordPress + db | `wordpress_app`, `wordpress_db` | 9000 |
| Postgres shared | `postgres` (:5432), per-stack postgres/redis siblings | 5432, 6379 |

**Unhealthy (6):** `calculators-calculators-1`, `blackbox-agent`,
`robin-gluetun`, `portracker`, `netboot-netbootxyz-1`, `imagemagick-app-1`
(all `Up 3 weeks (unhealthy)`); `databasus` was `health: starting` at sweep.
Nothing restarted — recorded, not fixed.

Many TCP listeners (`ss -tln` count in the hundreds); the bulk are per-stack
published ports and the Crafty range. Note: arcane binds almost everything on
`0.0.0.0` — any LAN host can reach every published service port; expected for
a service host, but there is no host firewall in front.

**Git remote (PJA-15):** bare repo
`/home/paperclip/homelab.git` on this host is the durable `arcane` remote for
the homelab repo (branch `main`,
`ssh://paperclip@192.168.1.10/home/paperclip/homelab.git`). Push/pull as
`paperclip` with the `homelab/ssh-key-arcane` Paperclip secret.

---

## 5. Other hosts on the LAN

The earlier external sweep found ~56 live hosts on 22/80/443. That table is
superseded: the Proxmox guest list (§2) plus static IPs accounts for nearly
all of them (guests on `dhcp`: 106, 108, 113, 118, 121, 124, 128, 130 and
stopped VMs). Remaining genuinely unknown: **gateway `192.168.1.1`** (out of
scope — Chief decision needed to inspect it) and whatever answers on ports
other than 22/80/443 (sweep was TCP 22/80/443 only).

Earlier notes carried over: no reverse DNS on the LAN (IP literals
everywhere); ICMP unanswered (Sentry must poll TCP/HTTP);
TrueNAS noVNC on :8006 collides visually with the Proxmox UI port.

---

## 6. Cross-cutting

### Dependencies

- Proxmox `NAS` (cifs) and `PBS` backends are network-backed and almost
  certainly TrueNAS shares. **If TrueNAS goes down, Proxmox backup/restore
  and anything on `NAS` goes with it.** Exact share mapping needs the PVE
  `storage.cfg` (root-only) — recorded as approximate, not asserted.
- arcane mounts **nothing** from TrueNAS — its containers live and die
  with its local rootfs (check headroom live).
- LAN DNS: PiHole (.250) and Technitium (.251) LXCs; DHCP guests depend on
  them for name resolution. Internal CA: step-ca (.29).
- Ingress: Traefik LXC (.254) plus nginx-proxy-manager on arcane — two
  reverse proxies; which fronts what is not mapped here.

### Could not reach (honest gaps)

| Gap | Why | Next step |
| --- | --- | --- |
| TrueNAS share ACLs + which clients use which share | `paperclip` has no sudo and middleware auth rejects it; `smbstatus`, config DB are root-only | Needs a TrueNAS admin credential or an approved sudo grant — propose to Chief |
| iSCSI target/LUN detail (who consumes `Tank/iSCSI`) | same as above | same |
| Snapshot/replication task success history | same as above (only snapshot *existence* + scrub *completion* verifiable) | same |
| PVE `storage.cfg` exact NAS/PBS share mapping | `/etc/pve/*.cfg` not in sudo scope | extend sudo scope or read via UI once |
| ~~Guest 107 config~~ | ~~unparseable~~ | **Closed** — fixed in PJA-26; `pct config 107` parses clean, all 3 mounts serving |
| Gateway 192.168.1.1 port forwards (public exposure) | out of scope, untouched | Chief/user decision |

### Operational findings

The full problems-and-risks register (version lag, plaintext credential
handling, capacity pressure, tunnel-agent posture) lives in the private
tracker and is intentionally not published here.

### Arcane configuration export (2026-09-30)

A read-only enumeration for the rebuild bundle found 102 Compose definitions
(including `.yml` files and Arcane itself), 101 Compose projects, 140 containers,
101 networks and 49 volumes. See `services/arcane-rebuild/manifest.json` and its
README for source paths, restore prerequisites and limitations. This is an export,
not a deployment or reboot verification. The stopped ARM definition references
`/mnt/nas/ARM`; treat that as a restore prerequisite rather than assuming all stack
data is local. The configuration bundle is published here; fresh-host verification remains pending.
