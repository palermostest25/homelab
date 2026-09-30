# services/

One directory per deployed service: `services/<name>/`.

A service directory is the declarative source of truth for that service. The
host is expected to match it exactly — §4 of
[`DEPLOY-STANDARD.md`](../DEPLOY-STANDARD.md) proves that with an empty diff:

```bash
ssh <host> cat /opt/<name>/docker-compose.yml | diff - services/<name>/docker-compose.yml
```

## Contents

| File | When |
| --- | --- |
| `docker-compose.yml` | Compose stack. Must carry `restart: unless-stopped` in the committed file. |
| `<name>.service` | systemd unit. Must be `enabled`, not just started. |
| `provision.sh` | `pvesh` / `pct` / `qm` / `midclt` provisioning. Idempotent and re-runnable. |
| `.env.example` | Key names only. Never real values — those go in the Paperclip vault. |
| `README.md` | Required. See below. |

## README.md template

All eight headings are required by §5 of the standard. A README with install
steps and no restore path is an automatic rejection.

```markdown
# <name>

## What it is
## Host and address
## Ports
## Start / stop / upgrade
## Data location
## Backup and restore
## Healthcheck
## Dependencies
```

- **Healthcheck** must be one pollable command or URL with its expected result,
  observed passing *and* failing before the change is called done.
- **Data location** must name a TrueNAS dataset with a snapshot task, or state
  explicitly that the data is ephemeral and say how it is rebuilt.
- **Dependencies** is what must already be up — a NFS mount, a database, the
  hypervisor's storage — because that is what breaks the cold-boot test.
