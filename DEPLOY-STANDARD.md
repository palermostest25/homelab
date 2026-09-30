# Homelab Deploy Standard — Definition of Done (v1)

Owner: Sentry. Applies to every change on **Proxmox VE 192.168.1.3**, **TrueNAS 192.168.1.2**, **arcane 192.168.1.10**.

Derived from the user's definition of finished: *"the thing works, will restart on boot etc, prod ready, and won't break tomorrow, with proper docs, and uploaded to GitHub if its a project."*

**Rule 0 — evidence over assertion.** Every line below is proved by real command output pasted into the ticket. A claim without quoted output is a FAIL, even when the claim is true.

---

## 1. Restarts on boot

| Shape | Proof command | Passing output |
| --- | --- | --- |
| systemd unit | `systemctl is-enabled <unit>` | `enabled` |
| Docker Compose | `docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' <container>` **and** `systemctl is-enabled docker` | `unless-stopped` (or `always`) + `enabled` |
| Proxmox guest | `qm config <vmid> \| grep onboot` (VM) or `pct config <ctid> \| grep onboot` (LXC) | `onboot: 1` |
| TrueNAS app | `midclt call app.query '[["name","=","<app>"]]' \| jq '.[].state'` (older releases: `chart.release.query`) — plus the app's container restart policy via `docker inspect` | `RUNNING` + `unless-stopped`/`always` |

- Compose must also carry `restart: unless-stopped` in the **committed** file, not just on the running container.
- **Negative:** "I added `restart: unless-stopped` to the compose file" with no `docker inspect` output. The running container can predate the edit. FAIL.
- **Negative:** a Proxmox guest that boots but whose `startup` order runs before its NFS storage is up. `onboot: 1` is necessary, not sufficient — §3 is what proves it.

## 2. Healthcheck

Every service exposes exactly one documented, pollable check:

- **HTTP** — a URL and expected status: `curl -fsS -o /dev/null -w '%{http_code}\n' http://192.168.1.10:8096/health` → `200`.
- **Container** — a `HEALTHCHECK` in the image or a `healthcheck:` block in compose: `docker inspect -f '{{.State.Health.Status}}' <container>` → `healthy`.
- **Neither applies** — a one-line command in the README under `## Healthcheck` that exits non-zero when the service is broken.

The check must be exercised **in both directions**: stop the service, quote the failing output, start it, quote the passing output. No healthcheck means the service cannot be monitored, which means it is not done.

- **Negative:** "check the web UI loads" — not pollable. FAIL.
- **Negative:** a 200 from a login page that renders fine while the database behind it is down. The check must depend on the thing actually working.
- **Negative:** a healthcheck that was written but never observed to fail.

## 3. Cold-boot verification

The service returns unattended after a full restart, with nobody logging in.

1. State the intent and the **blast radius** in the ticket ("rebooting LXC 104; nothing else rides on it") and confirm the window is acceptable.
2. Reboot the **single guest**, never its hypervisor, unless the change is the hypervisor itself. Rebooting 192.168.1.3 takes every guest down with it.
3. Capture `uptime -s` before and after — it must change.
4. Poll the §2 healthcheck **from a different machine**, not from an SSH session on the box, until it passes or 5 minutes elapse. Quote the output and the timestamp.

**Who:** Warden reboots and posts the evidence. Sentry re-runs the healthcheck independently and issues the verdict. Warden's own paste is necessary, not sufficient.

- **Negative:** `systemctl is-enabled` offered as the cold-boot proof. Enabled units still die on boot from missing mounts, dependency ordering, or a NAS share that isn't up yet.
- **Negative:** SSHing in after the reboot and running `docker compose up -d` "just to be sure". That invalidates the test. Redo it.

## 4. Configuration lives in git

Compose files, unit files, `pvesh`/`midclt` provisioning scripts, and deploy scripts live in the homelab repo under `services/<name>/`. Secrets never do — commit `.env.example` with key names only; real values go in a Paperclip secret and are referenced by name.

**Proof:** the commit hash, plus an empty host-vs-repo diff:
`ssh <host> cat /opt/<svc>/docker-compose.yml | diff - services/<svc>/docker-compose.yml` → no output.

- **Negative:** a change that exists only as commands typed over SSH. FAIL regardless of whether it works.
- **Negative:** a compose file in the repo that has drifted from the host. The diff is the proof; the file merely existing is not.

## 5. README requirements

`services/<name>/README.md` (repo root for a project), with **all** of these headings:

What it is · Host and address · Ports · Start / stop / upgrade (exact commands) · Data location · Backup and restore · Healthcheck · Dependencies (what must be up first)

- **Negative:** install steps and no restore path. FAIL. This is the most common miss and the one that matters at 3am.
- **Negative:** "data is in a docker volume" with no path and no snapshot coverage.

## 6. GitHub — project vs config tweak

Both go in git. The only question is *which* repo. Tie-break in order:

1. Did we write code that is not merely configuration? → **project**.
2. Would it still make sense on a machine that is not in this lab? → **project**.
3. Otherwise → **config tweak**.

A **project** gets its own GitHub repo with the README at the root. A **config tweak** goes in the homelab repo only.

Worked examples: standing up Jellyfin = tweak. A script we wrote that syncs Jellyfin metadata to TrueNAS = project. Prometheus/Alertmanager config = tweak. A custom exporter we wrote = project. Adding a mount, changing a threshold = tweak.

## 7. Data and backup posture

Every service names where its persistent data lives, and is one of:

- **On a TrueNAS dataset with a periodic snapshot task** — name the dataset and the task; prove with `zfs list -t snapshot <dataset> | tail -3` showing recent snapshots.
- **Deliberately ephemeral and rebuildable from the repo** — say so explicitly and say how it is rebuilt.

Anything else is a FAIL. The restore path is **tested once at deploy time**: restore into a scratch location, prove the data came back, quote it. An untested restore is a hypothesis.

- **Negative:** "data is on the TrueNAS pool." A pool is not a snapshot. Name the snapshot task and show the snapshots.

## 8. LAN-only by default

No router port forwards, no public DNS records, no tunnels (Cloudflare, Tailscale Funnel, ngrok), no publicly-trusted reverse proxy — **per service**, without the user's explicit approval recorded in the ticket.

**Proof:** an explicit statement in the ticket that no forward, DNS record, or tunnel was added, plus the reverse-proxy `listen`/`server_name` config if one is involved. Monitoring dashboards and metrics endpoints are unauthenticated and describe the shape of the whole lab — they are LAN-only, always.

- **Negative:** "I put it behind a Cloudflare Tunnel so it's secure" with no approval. That is internet exposure. Revert and ask.

## 9. Inventory update

The PJA-12 `inventory` document is updated **in the same change** that deploys the service: host/guest, ports, data location, snapshot coverage, boot behaviour. Proof: link the inventory revision in the ticket.

- **Negative:** "I'll update the inventory after." Not done.

## 10. Review checklist

Run per change. Every line is pass/fail with the stated evidence.

| # | Check | Required evidence |
| --- | --- | --- |
| 1 | Boot-enabled | quoted `systemctl is-enabled` / `docker inspect …RestartPolicy` / `onboot: 1` / app state |
| 2 | Healthcheck | the command or URL, with **both** healthy and failing output |
| 3 | Cold boot | `uptime -s` before/after + healthcheck polled from another machine, no login |
| 4 | Config in git | commit hash + empty host-vs-repo diff |
| 5 | README | all 8 headings present, restore path included |
| 6 | Right repo | project → own GitHub repo, README at root; tweak → homelab repo |
| 7 | Data + backup | dataset + recent `zfs list -t snapshot` + a restore actually performed |
| 8 | LAN-only | explicit no-forward/no-DNS/no-tunnel statement, or the user's recorded approval |
| 9 | Inventory | link to the updated inventory revision |
| 10 | No secrets | `.env.example` only; values in the vault, referenced by name |

**Automatic rejections** — straight back to the owner, no discussion:

- "Deployed successfully" / "it's working" / "looks healthy" with no quoted output.
- A service started by hand after the reboot test.
- Config that exists only on the host.
- A README with install steps but no restore path.
- A screenshot of a green dashboard as the only evidence.
- A healthcheck that was never seen to fail.
- Any credential in a comment, commit, document, or log. Hard stop, and the secret gets rotated.

**Scope exemption.** A one-line reversible change that introduces no new service (a threshold tweak, a log-rotate setting) needs lines 4, 9 and 10 only. Claim the exemption explicitly in the ticket; do not apply it silently.
