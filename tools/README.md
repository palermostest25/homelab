# tools/

Scripts that set up the **agent's own workstation** — the Paperclip runner —
rather than a lab host. Nothing in here touches 192.168.1.0/24.

A lab service belongs in `services/<name>/`. Host access belongs in `access/`.

## `install-git.sh`

### What it is

Installs `git` for the agent account without root. The Paperclip runner image
ships no `git` and no `gh`, and the agent has no sudo, no `apt`, no `dpkg`, no
`ar` and no `zstd`. Three PJA-15 heartbeats failed on
`git: command not found` before this existed.

It unpacks the Ubuntu `git` `.deb` using python3 stdlib only, fetching the
`zstandard` wheel on the fly because Ubuntu compresses `data.tar` with zstd and
python 3.10 cannot read that natively.

### Run it

```bash
./tools/install-git.sh
```

Idempotent. If a working `git` is already on `PATH` it prints the version and
exits without touching the filesystem, so it is safe at the top of any
heartbeat.

Useful overrides:

| Variable | Default | Why |
| --- | --- | --- |
| `PREFIX` | `/home/paperclip/.local` | Install root |
| `GIT_DEB_FILE` | — | Use a specific local `.deb` |
| `GIT_DEB_URL` | — | Use a specific URL |
| `GIT_DEB_VERSION` | `2.34.1-1ubuntu1.17` | Pinned pool version |
| `GIT_DEB_POOL` | `archive.ubuntu.com` git pool | Mirror to resolve from |

### Where things land

```
/home/paperclip/.local/bin/git              wrapper script (this is what PATH finds)
/home/paperclip/.local/libexec/git-core/    the real binary and its subcommands
/home/paperclip/.local/share/git-core/      templates
/home/paperclip/.local/src/git_*.deb        cached package, so a re-run needs no network
```

`/home/paperclip/.local/bin` is already on the runner's `PATH`.

**The prefix is not `$HOME`.** On the Paperclip runner `$HOME` is a per-run
temporary directory that is deleted when the run ends. `/home/paperclip`
persists, which is the only reason the next heartbeat finds the binary. An
earlier attempt installed to `$HOME/.local` and vanished.

### Why a wrapper and not the binary

Ubuntu builds `git` without `RUNTIME_PREFIX`, so it looks for its subcommands in
the compiled-in `/usr/lib/git-core`, which does not exist here. The wrapper sets
`GIT_EXEC_PATH` and `GIT_TEMPLATE_DIR` and then `exec`s the real binary, which
keeps that detail out of every caller's environment.

The wrapper sets *only* those two variables. It must never touch
`GIT_CONFIG_*`, `GIT_AUTHOR_*`, `GIT_COMMITTER_*` or any token variable — see
below.

### Healthcheck

```bash
git --version && git --exec-path
```

Expected: `git version 2.34.1` and `/home/paperclip/.local/libexec/git-core`.
The script goes further and runs a real `init` + `add` + `commit` in a
throwaway directory before reporting success; a `--version` that works proves
very little.

### Recovery

Re-run the script. There is no state to repair — it replaces `libexec/git-core`
and `share/git-core` wholesale every cold run.

### Gotcha: `fatal: empty ident name (for <>) not allowed`

Setting `user.name` in `.git/config` is not enough to commit here. Two separate
things blank the identity:

1. **The run environment itself.** Check it:

   ```
   GIT_AUTHOR_NAME=[]  GIT_AUTHOR_EMAIL=[]  GIT_COMMITTER_NAME=[]  GIT_COMMITTER_EMAIL=[]
   GIT_CONFIG_GLOBAL=[/dev/null]  GIT_CONFIG_SYSTEM=[/dev/null]  GIT_CONFIG_COUNT=[]
   ```

   An empty environment variable beats both `-c user.name=...` and
   `.git/config`, so the commit dies before it starts.

2. **The Paperclip GitHub launcher.** `git` on `PATH` resolves first to the
   launcher shim, which finds the real binary, injects managed GitHub
   credentials and `exec`s it. It *deletes* `GIT_AUTHOR_*`, `GIT_COMMITTER_*`,
   `GIT_CONFIG_*` and the token variables from the environment it inherits
   before setting its own. So exporting the identity and then calling `git`
   through `PATH` does not work either — the launcher throws your value away.

The recipe that works — set the identity inline **and** call the wrapper by
absolute path so the launcher cannot strip it:

```bash
cd <repo>
export GIT_AUTHOR_NAME=Warden    GIT_AUTHOR_EMAIL=warden@paperclip.ing
export GIT_COMMITTER_NAME=Warden GIT_COMMITTER_EMAIL=warden@paperclip.ing
unset GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
/home/paperclip/.local/bin/git commit -F - <<'MSG'
<subject>

<body>

Co-Authored-By: Paperclip <noreply@paperclip.ing>
MSG
```

Confirm it landed on the right identity rather than assuming:

```bash
/home/paperclip/.local/bin/git log -n 1 --format='%an <%ae> / %cn <%ce>'
```

Environment does not persist between tool calls, so the `export` lines have to
be in the *same* command as the commit.

Use the `git` on `PATH` only for operations that genuinely need GitHub
credentials, such as `push` to a GitHub remote. That is what the launcher is
for, and it is the one case where going around it would fail.

### Dependencies

`python3` (3.8+), `curl`, `bash`, and outbound HTTP to the Ubuntu pool and
`pypi.org` on a cold run. A cold run with a cached `.deb` still needs pypi for
the zstd wheel; a warm run needs nothing.
