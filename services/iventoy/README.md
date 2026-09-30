# iventoy

## What it is

iVentoy PXE/netboot server. It serves the lab's ISO library over PXE so a bare
machine on the LAN can network-boot an installer or a rescue image without a USB
stick. The ISO library itself lives on TrueNAS and is bind-mounted into the
guest — iVentoy stores no images of its own.

## Host and address

- Hypervisor: Proxmox VE, `192.168.1.3`
- Guest: **LXC 107**, hostname `iVentoy`, **privileged** (`unprivileged: 0`)
- Address: `192.168.1.20/24` static, gw `192.168.1.1`, bridge `vmbr0`
- Resources: 1 core, 1 G RAM, 2 G swap, rootfs `local:107/vm-107-disk-0.raw` (8 G)
- `onboot: 1` — starts with the hypervisor

`107.conf` in this directory is the committed copy of `/etc/pve/lxc/107.conf`.

## Ports

| Port | What | Notes |
| --- | --- | --- |
| 26000 | iVentoy web UI / control | the real service port |
| 80 | nginx | 301 redirect to `:26000` |
| 67/69 UDP | DHCP proxy + TFTP | PXE; not TCP-pollable |
| 22 | SSH | |

LAN-only. Nothing here is internet-facing and nothing should be.

## Start / stop / upgrade

Inside the guest the service is a systemd unit, `enabled`:

```bash
ssh paperclip@192.168.1.3 'sudo pct exec 107 -- systemctl {start,stop,restart} iventoy'
ssh paperclip@192.168.1.3 'sudo pct exec 107 -- systemctl is-enabled iventoy'   # -> enabled
```

Guest lifecycle from the hypervisor:

```bash
ssh paperclip@192.168.1.3 'sudo pct {start,shutdown,reboot} 107'
```

To upgrade iVentoy, replace `/root/iventoy` in the guest with the new release
and `systemctl restart iventoy`. The mount points are independent of the
release, so an upgrade never touches the ISO library.

### Editing the guest config

`pct set` **cannot** repair a mountpoint line it cannot parse — it stages the
change into `[pve:pending]` and then fails to apply it on restart, because
applying a pending change requires parsing the current value first. That is the
trap that left this guest broken. To rewrite the file wholesale:

```bash
# 107.conf.new is a complete, corrected config on the Proxmox host
sudo pct push 107 /path/to/107.conf.new /tmp/107.conf.new
sudo pct pull 107 /tmp/107.conf.new /etc/pve/lxc/107.conf
sudo pct config 107        # must print with zero parse warnings
sudo pct reboot 107        # mountpoint changes only take effect on restart
```

Back up `/etc/pve/lxc/107.conf` first; `/home/paperclip/config-backups/` on the
Proxmox host holds the pre-[PJA-26] copy.

## Data location

**No application data lives in this guest.** The rootfs holds only the iVentoy
binary and its config; it is disposable and rebuildable from this directory.

The ISO library lives on TrueNAS `192.168.1.2`, dataset path
`/mnt/Tank/Tank/Images`, reached over SMB and bind-mounted into the guest:

| mp | Proxmox host path | SMB share | TrueNAS path | Guest path |
| --- | --- | --- | --- | --- |
| mp0 | `/mnt/images` | `//192.168.1.2/images` | `/mnt/Tank/Tank/Images` | `/root/iventoy/iso/Images` |
| mp1 | `/mnt/images-updated` | `//192.168.1.2/images-updated` | `/mnt/Tank/Tank/Images-Updated` | `/root/iventoy/iso/Images-Updated` |
| mp2 | `/mnt/images/Rescue` | (subdir of `images`) | `/mnt/Tank/Tank/Images/Rescue` | `/root/iventoy/iso/Rescue` |

All three are **bind mounts of host paths**, not PVE storage volumes. They are
only as good as the host's CIFS mounts in `/etc/fstab` — see Dependencies.

> `mp2` points at a subdirectory of the `images` share because there is no
> `rescue` share on TrueNAS. The config previously named `/mnt/rescue`, which
> has never existed on the host: no directory, no fstab entry, no mount unit.
> Enumerating the server (`smbclient -L //192.168.1.2`) returns
> `Tank, Proxmox, Images, Images-Updated, win11, isolated, BigTank, Backups,
> TimeMachine, John, Pond` — no `rescue`. The only Rescue ISO set in the lab is
> `/mnt/Tank/Tank/Images/Rescue` (30 ISOs), so that is what mp2 binds.

### Backup and restore

The ISOs are TrueNAS's problem and are covered by that pool's snapshot tasks —
nothing in this guest needs backing up.

To rebuild the guest from scratch:

1. Recreate LXC 107 from `107.conf` in this directory (it is the whole config).
2. Install iVentoy into `/root/iventoy` and enable the `iventoy` unit.
3. Confirm the three host CIFS mounts are present, then `pct start 107`.

To roll back a bad config edit:

```bash
ssh paperclip@192.168.1.3
sudo pct push 107 /home/paperclip/config-backups/107.conf.pre-PJA-26 /tmp/rb.conf
sudo pct pull 107 /tmp/rb.conf /etc/pve/lxc/107.conf
```

## Healthcheck

One pollable URL:

```bash
curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://192.168.1.20:26000/
# expected: 200
```

**On a cold start this returns nothing for 60–90 s.** iVentoy indexes the whole
ISO library before it opens port 26000; with ~255 ISOs over CIFS that parse pass
takes over a minute. A poller must allow that grace period or it will report a
false outage on every reboot. Progress is visible in the guest at
`/root/iventoy/log/log.txt` (`Phase2 parse image ... finished success`).

Failing case observed: with the mount points detached, `:26000` answers 200 but
`/root/iventoy/iso/{Images,Images-Updated,Rescue}` are all empty and the server
serves nothing. **A 200 alone is not sufficient.** Pair it with a content check:

```bash
ssh paperclip@192.168.1.3 \
  "sudo pct exec 107 -- sh -c 'ls -1 /root/iventoy/iso/Images | wc -l'"
# expected: 16  (0 means the mounts are detached)
```

## Dependencies

What must already be up, in order — this is what breaks the cold-boot test:

1. **TrueNAS `192.168.1.2`** with SMB running and the `images` /
   `images-updated` shares exported.
2. **The Proxmox host's CIFS mounts**: `mnt-images.mount` and
   `mnt-images\x2dupdated.mount`. mp2 rides on `mnt-images.mount`.
3. Only then LXC 107.

> **Durability state (PJA-34, 2026-09-29).** Both fstab entries now
> carry `_netdev,x-systemd.automount,x-systemd.mount-timeout=30`, applied by
> human root. `mnt-images.mount` and `mnt-images\x2dupdated.mount` are both
> `active (mounted)` with generated `.automount` units present. Cold-boot
> survival has **not** been proven across a Proxmox reboot (reboot declined in
> PJA-29) — the next host reboot is the real test.
