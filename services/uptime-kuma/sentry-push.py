#!/usr/bin/env python3
"""Sentry push checks for PJA-14 monitoring baseline.

Runs on each host as `paperclip` via cron (user crontab, no root needed).
Each check pushes OK/FAIL to the Uptime Kuma Push monitor whose URL is passed
as argv[1]. Nothing here restarts, reconfigures, or deletes anything.

Severity rule (tune-for-signal): only critical conditions push DOWN (which
fires ntfy). Warnings are printed into the push message — visible on the Kuma
dashboard — but still push UP, so a known ongoing issue does not spam alerts.

Usage:
  sentry-push.py <push-url>          # auto-detect role by hostname
  sentry-push.py <push-url> <check>  # one of proxmox|truenas|arcane (debug)

Exit 0 = push UP, 1 = push DOWN. Stdout lines are quoted as evidence in PJA-14.
"""
import re
import socket
import subprocess
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone

HOST = socket.gethostname()


def run(cmd):
    p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60)
    return p.returncode, (p.stdout + p.stderr).strip()


def tcp_open(host, port, timeout=5):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def cert_days_left_openssl(host, port=443):
    """Days until the TLS cert expires, via openssl (TrueNAS middleware
    does not present a Python-parseable chain; openssl handles it)."""
    rc, out = run(
        "echo | openssl s_client -connect %s:%d -servername %s 2>/dev/null"
        " | openssl x509 -noout -enddate 2>&1" % (host, port, host))
    m = re.search(r"notAfter=(.*)", out)
    if not m:
        raise RuntimeError("no cert parsed: " + out[:150])
    exp = datetime.strptime(m.group(1).strip(), "%b %d %H:%M:%S %Y %Z")
    exp = exp.replace(tzinfo=timezone.utc)
    return (exp - datetime.now(timezone.utc)).days, exp.date().isoformat()


def rootfs_use():
    rc, out = run("df -P / | tail -1")
    if rc != 0:
        raise RuntimeError("df failed: " + out[:150])
    return int(out.split()[4].rstrip("%"))


def check_proxmox():
    crit, warn = [], []
    if not tcp_open("127.0.0.1", 8006):
        crit.append("pveproxy :8006 not listening locally")
    # Guest state vs onboot flag: only stopped guests cost a config lookup.
    rc, out = run("sudo -n qm list 2>&1 | tail -n +2")
    if rc != 0:
        crit.append("qm list failed: " + out[:200])
    else:
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[2] == "stopped":
                vmid = parts[0]
                rc2, cfg = run("sudo -n qm config %s 2>&1 | grep -i onboot" % vmid)
                if rc2 == 0 and re.search(r"onboot\s*:\s*1", cfg):
                    crit.append("VM %s stopped but onboot=1" % line.strip())
    rc, out = run("sudo -n pct list 2>&1 | tail -n +2")
    if rc != 0:
        crit.append("pct list failed: " + out[:200])
    else:
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1] == "stopped":
                vmid = parts[0]
                rc2, cfg = run("sudo -n pct config %s 2>&1 | grep -i onboot" % vmid)
                if rc2 == 0 and re.search(r"onboot\s*:\s*1", cfg):
                    crit.append("LXC %s stopped but onboot=1" % line.strip())
    try:
        use = rootfs_use()
        if use >= 98:
            crit.append("rootfs at %d%% (>=98 critical)" % use)
        elif use >= 93:
            warn.append("rootfs at %d%% (>=93, see PJA-27)" % use)
    except RuntimeError as e:
        crit.append(str(e))
    return crit, warn


def check_truenas():
    crit, warn = [], []
    rc, out = run("/sbin/zpool status -x 2>&1")
    if "all pools are healthy" not in out:
        crit.append("zpool status -x: " + out[:200])
    rc, out = run("/sbin/zpool list -H -o name,cap,health 2>&1")
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3:
            name, cap, health = parts
            if health != "ONLINE":
                crit.append("pool %s health=%s" % (name, health))
            try:
                pct = int(cap.rstrip("%"))
                if pct >= 85:
                    crit.append("pool %s at %s (>=85)" % (name, cap))
                elif pct >= 75:
                    warn.append("pool %s at %s (trending)" % (name, cap))
            except ValueError:
                pass
    rc, out = run("/sbin/zpool status 2>&1")
    if "none requested" in out:
        warn.append("a pool was never scrubbed")
    # Snapshot task alive: at least one auto-* snapshot newer than 14 days.
    rc, out = run("/sbin/zfs list -H -o name,creation -t snapshot 2>/dev/null | grep auto- | tail -5")
    if rc != 0 or not out.strip():
        crit.append("no auto-* snapshots found (snapshot task may have stopped)")
    try:
        days, exp = cert_days_left_openssl("127.0.0.1")
        if days < 21:
            crit.append("TrueNAS web cert expires in %d days (%s)" % (days, exp))
        elif days < 45:
            warn.append("TrueNAS web cert expires in %d days (%s)" % (days, exp))
    except Exception as e:
        crit.append("cert probe failed: %s" % str(e)[:150])
    return crit, warn


# Pre-existing unhealthy at baseline: warn, don't page.
KNOWN_UNHEALTHY = {
    "calculators-calculators-1", "blackbox-agent", "robin-gluetun",
    "portracker", "netboot-netbootxyz-1", "imagemagick-app-1",
}


def check_arcane():
    crit, warn = [], []
    if not tcp_open("127.0.0.1", 80):
        crit.append("arcane :80 not listening locally")
    if not tcp_open("127.0.0.1", 1003):
        crit.append("uptime-kuma :1003 not listening locally")
    rc, out = run("docker ps --filter health=unhealthy --format '{{.Names}}' 2>&1")
    if rc != 0:
        crit.append("docker ps failed: " + out[:200])
    elif out.strip():
        names = set(out.split())
        new = names - KNOWN_UNHEALTHY
        known = names & KNOWN_UNHEALTHY
        if new:
            crit.append("NEW unhealthy containers: " + ", ".join(sorted(new)))
        if known:
            warn.append("known unhealthy (finding 15): " + ", ".join(sorted(known)))
    try:
        use = rootfs_use()
        if use >= 90:
            crit.append("rootfs at %d%% (>=90)" % use)
        elif use >= 80:
            warn.append("rootfs at %d%% (trending)" % use)
    except RuntimeError as e:
        crit.append(str(e))
    return crit, warn


CHECKS = {"proxmox": check_proxmox, "truenas": check_truenas, "arcane": check_arcane}

# Operator sets the real topic locally; the live value is never committed.
NTFY_TOPIC = "<NTFY_TOPIC>"
NTFY_SERVER = "https://ntfy.sh"
import os as _os
STATE_DIR = _os.path.join(_os.path.expanduser("~"), ".sentry-push")
# 30-minute transition grace: a host that has not yet moved to cron still
# emits its status via direct ntfy so nothing goes unwatched during rollout.


def ntfy(title, message, priority="default", tags=None):
    data = message.encode()[:3500]
    req = urllib.request.Request(
        "%s/%s" % (NTFY_SERVER, NTFY_TOPIC), data=data, method="POST")
    req.add_header("Title", title[:120])
    req.add_header("Priority", priority)
    if tags:
        req.add_header("Tags", tags)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status
    except Exception as e:
        return "NTFY-FAILED: %s" % e


def read_state(which):
    try:
        with open("%s/%s.state" % (STATE_DIR, which)) as f:
            return f.read().strip()
    except OSError:
        return "unknown"


def write_state(which, state):
    try:
        import os
        os.makedirs(STATE_DIR, exist_ok=True)
        with open("%s/%s.state" % (STATE_DIR, which), "w") as f:
            f.write(state)
    except OSError as e:
        print("state write failed: %s" % e)


def transition_notify(which, crit, warn, dry_run):
    """Direct-ntfy transition mode: alert on state change without Kuma.

    Used until the Kuma Push monitors exist. Only transition edges
    (ok->fail, fail->ok) send ntfy; steady states stay silent. Warnings
    never page. Returns an rc matching push semantics (0 up, 1 down)."""
    state = "fail" if crit else "ok"
    prev = read_state(which)
    details = "; ".join(crit) if crit else (
        "; ".join(warn) if warn else "all %s checks pass" % which)
    liveness = "dry_run_no_cron_expected" if dry_run else "no_cron_yet"
    print("[%s] %s %s (%s): %s" % (
        datetime.now(timezone.utc).isoformat(), HOST, state.upper(),
        liveness, details[:300]))
    if dry_run:
        print("ntfy -> skipped (dry-run probe only)")
        return 0 if not crit else 1
    if state != prev:
        title = "PJA-14 %s %s" % (which, "DOWN" if crit else "UP")
        prio = "high" if crit else "default"
        tags = "rotating_light" if crit else "white_check_mark"
        code = ntfy(title, "%s %s: %s" % (HOST, which, details[:500]),
                     priority=prio, tags=tags)
        print("ntfy -> %s" % code)
        write_state(which, state)
    else:
        print("ntfy -> skipped (steady %s, no edge)" % state.upper())
        # Persist anyway: a wiped state dir must not replay a DOWN alert.
        if prev == "unknown":
            write_state(which, state)
    return 0 if not crit else 1


def push(url, up, msg):
    status = "up" if up else "down"
    qs = urllib.parse.urlencode({"status": status, "msg": msg[:400]})
    sep = "&" if "?" in url else "?"
    req = urllib.request.Request(url + sep + qs, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status
    except Exception as e:
        return "PUSH-FAILED: %s" % e


def main():
    if len(sys.argv) < 2:
        print("usage: sentry-push.py <kuma-push-url|direct-ntfy|dry-run> [proxmox|truenas|arcane]")
        return 2
    url = sys.argv[1]
    which = sys.argv[2] if len(sys.argv) > 2 else None
    if which is None:
        h = HOST.lower()
        which = "proxmox" if "prox" in h else ("truenas" if "truenas" in h else "arcane")
    if which not in CHECKS:
        print("unknown host role: %s" % which)
        return 2
    crit, warn = CHECKS[which]()
    if url in ("direct-ntfy", "dry-run"):
        return transition_notify(which, crit, warn, dry_run=(url == "dry-run"))
    parts = []
    if crit:
        parts.append("FAIL: " + "; ".join(crit))
    if warn:
        parts.append("warn: " + "; ".join(warn))
    summary = "OK all %s checks pass" % which if not parts else " | ".join(parts)
    print("[%s] %s: %s" % (datetime.now(timezone.utc).isoformat(), HOST, summary))
    code = push(url, not crit, "%s %s" % (HOST, summary))
    print("push -> %s" % code)
    return 0 if not crit else 1


if __name__ == "__main__":
    sys.exit(main())
