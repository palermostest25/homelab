# uptime-kuma (monitoring stack)

> What it is · Host and address · Ports · Start / stop / upgrade (exact commands)
> · Data location · Backup and restore · Healthcheck · Dependencies

## What it is

Uptime Kuma 2.0.2 — the lab's monitoring stack (adopted, not newly deployed;
see PJA-14 for the Kuma-over-Prometheus justification).
Two layers:

1. **Poll layer (pre-existing):** 10 ping monitors (30/60 s) covering TrueNAS,
   Proxmox, arcane, PBS, UniFi, gateways, PiKVM, QNAP, office hosts. All bound
   to the `NTFY Alert` notification.
2. **Push layer (PJA-14, live):** `sentry-push.py` runs on each host every 5 min
   via the `paperclip` user crontab, pushing to the Kuma Push monitors
   `sentry-push-proxmox` (id 22), `sentry-push-truenas` (id 23),
   `sentry-push-arcane` (id 24) — 5-min interval, each bound to the `NTFY
   Alert` notification. The monitors' missed-push timeout is the
   dead-man's-switch: if a host's cron dies (or arcane loses the LAN), Kuma
   marks the monitor DOWN past timeout and ntfy fires. Push checks cover
   what ping cannot: guest onboot state, pool health/capacity,
   scrub/snapshot freshness, disk trend, TLS expiry, unhealthy containers.
   Severity: only critical conditions push DOWN (which fires ntfy via Kuma);
   warnings ride in the push message (dashboard-visible, no alert spam).
3. **Retired:** the `direct-ntfy` transition mode (script posted straight to
   ntfy on state edges) is superseded by the Push monitors above. The
   `direct-ntfy`/`dry-run` argv modes remain in the script as a fallback for
   maintenance windows and offline debugging.

## Host and address

arcane (Proxmox LXC 102), 192.168.1.10. UI: `http://192.168.1.10:1003/` (LAN-only).

## Ports

- `1003/tcp` → container `:3001` (Kuma web + `/api/push/<token>` ingress).
- Push URLs are per-monitor secrets: `http://192.168.1.10:1003/api/push/<token>`.
  Tokens live only in Kuma's `kuma.db` and in each host's crontab line — never
  in this repo, never in a ticket comment.

## Start / stop / upgrade

```bash
# status
ssh -i <homelab/ssh-key-arcane> paperclip@192.168.1.10 \
  'docker inspect uptime-kuma-uptimekuma-1 --format "{{.State.Status}} {{.State.Health.Status}}"'
# restart (safe: stateless UI, state in /app/data volume)
ssh -i <homelab/ssh-key-arcane> paperclip@192.168.1.10 \
  'docker restart uptime-kuma-uptimekuma-1'
# upgrade: bump image tag in compose.yml, then
ssh -i <homelab/ssh-key-arcane> paperclip@192.168.1.10 \
  'docker compose -f /opt/docker/stacks/uptime-kuma/compose.yml up -d'
```

## Data location

- Kuma state: `/opt/docker/appdata/uptimekuma/data/kuma.db` (sqlite) on arcane.
- Compose: `/opt/docker/stacks/uptime-kuma/compose.yml` (`restart: always`).
- Push checks: `services/uptime-kuma/sentry-push.py` (this repo); installed copy
  `/home/paperclip/sentry-push.py` on Proxmox and arcane,
  `/mnt/Apps/paperclip/sentry-push.py` on TrueNAS (home is on the Apps pool);
  schedule in the `paperclip` user crontab (`crontab -l`). Each cron line
  passes its host's Kuma Push URL
  (`http://192.168.1.10:1003/api/push/<TOKEN> <role>`). Push URL tokens live
  only in Kuma's `kuma.db` and in each host's crontab line — never in this
  repo, never in a ticket comment. Monitor management: `kuma.js`
  (`KUMA_PW_FILE` or `KUMA_PASSWORD`, user `denby`); `list` prints monitors,
  `ensure-push` idempotently creates/binds/tokens the 3 push monitors.

## Backup and restore

Kuma's sqlite db holds all monitor/notification history. Covered by the arcane
rootfs path: arcane itself is a guest on `SSD` storage; Kuma data restores with
the container volume from host backup. Push-check source of truth is this repo
(re-install = copy file + crontab line, see install below).

## Healthcheck

- Pollable: `curl -o /dev/null -w '%{http_code}\n' http://192.168.1.10:1003/` → `302`
  (login redirect = app up). Container: `{{.State.Health.Status}}` → `healthy`.
- Push layer self-check: each host pushes every 5 min; a missed push past the
  5-min monitor interval flips the monitor DOWN and ntfy fires (dead-man's
  switch — a dead cron produces an alert, not silence). To prove an edge
  path: push `?status=down`, confirm the Kuma DOWN + ntfy alert, push
  `?status=up`, confirm recovery.
- Monitor-death detection: **in place.** Kuma itself has `restart: always` +
  `healthy` + `docker enabled`, and each Push monitor's missed-push timeout
  catches per-host cron death. Residual limitation (stated plainly): if
  arcane itself dies, the LAN gets no ntfy — LAN-only delivery cannot page
  when the whole LAN or arcane is down (accepted with the user's `ntfy_keep`
  channel choice).

## Dependencies

- Docker on arcane (`systemctl is-enabled docker` → `enabled`); the
  `/var/run/docker.sock` read-only mount (container-count info only).
- `ntfy.sh` reachable for alert egress (`https://ntfy.sh`, topic `<NTFY_TOPIC>` —
  the operator sets the real topic locally, never in this repo).
- Per-host inputs: Proxmox needs `sudo -n qm/pct` (granted); TrueNAS needs
  `/sbin/zpool|zfs` on PATH (works, no sudo); arcane needs `docker ps` (user is
  in the `docker` group).

## Install / reinstall (per host)

```bash
KEY=~/.ssh/<homelab/ssh-key-...>   # Paperclip secret, by name only
# NOTE: TrueNAS home is /mnt/Apps/paperclip, not /home/paperclip
scp -i $KEY services/uptime-kuma/sentry-push.py paperclip@<host>:sentry-push.py
# dry run (no alert, no state change): expect rc=0 with warnings, or rc=1 listing FAILs
ssh -i $KEY paperclip@<host> 'python3 ~/sentry-push.py dry-run <proxmox|truenas|arcane>; echo rc=$?'
# live (transition mode — posts ntfy only on state edges):
ssh -i $KEY paperclip@<host> '(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/bin/python3 ~/sentry-push.py direct-ntfy <role> >> ~/sentry-push.log 2>&1") | crontab -'
# after the Kuma Push monitors exist (live since PJA-14 close-out — this is
# the current state; same script, same thresholds; push DOWN = critical only,
# warnings ride along):
ssh -i $KEY paperclip@<host> '(crontab -l 2>/dev/null | grep -v sentry-push; echo "*/5 * * * * /usr/bin/python3 ~/sentry-push.py http://192.168.1.10:1003/api/push/<TOKEN> <role> >> ~/sentry-push.log 2>&1") | crontab -'
# Push URL tokens: created server-side via kuma.js ensure-push (user denby
# auth), stored only in Kuma's kuma.db + each host's crontab. Recreate with:
# KUMA_PW_FILE=<path-with-password> node kuma.js ensure-push
```

## Alerting

Channel: ntfy topic `<NTFY_TOPIC>` on `https://ntfy.sh` — the operator sets the
real topic locally, never in this repo. Severity: push DOWN (critical only)
fires ntfy; warnings ride in the push message (dashboard-visible, no alert
spam).

## Responses (runbook)

| Alert | Meaning | Response |
| --- | --- | --- |
| `sentry-push-proxmox DOWN` (Kuma → ntfy) | guest stopped vs onboot, :8006 down, or rootfs ≥98% | `sudo qm/pct list`, start guest / free `local` (see PJA-27) |
| `sentry-push-truenas DOWN` (Kuma → ntfy) | pool not ONLINE, pool ≥85%, no auto-snaps, cert <21d | `zpool status`, snapshot task check, renew cert |
| `sentry-push-arcane DOWN` (Kuma → ntfy) | :80/:1003 down, NEW unhealthy container, rootfs ≥90% | `docker ps`, restart container, free disk |
| Push monitor DOWN with host reachable (pushes stopped arriving) | cron died on that host | `crontab -l`, check `~/sentry-push.log`, re-run script by hand |
| Kuma UI down (:1003 refused) | monitor itself dead | `docker restart uptime-kuma-uptimekuma-1`; note: LAN gets no ntfy while arcane is down (accepted limitation) |

## Maintenance mode

Pause one host's cron line (`crontab -e`, comment it) during work on that host;
Kuma will go DOWN past timeout — use Kuma Maintenance for the window instead so
no alert fires. Re-enable after.
