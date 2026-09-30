#!/usr/bin/env bash
#
# Install git for the Paperclip agent account, unprivileged and idempotent.
#
# The Paperclip runner image ships no git binary and the agent account has no
# sudo, no apt, no dpkg, no ar and no zstd. Three PJA-15 heartbeats died on
# `git: command not found`, so the fix is a file you can re-apply instead of a
# sequence somebody has to remember.
#
# Run it as many times as you like. If a working git is already on PATH it
# exits immediately without touching anything.
#
#   ./tools/install-git.sh
#
# Override the install prefix or the package source if the defaults are wrong:
#
#   PREFIX=/home/paperclip/.local ./tools/install-git.sh
#   GIT_DEB_URL=http://.../git_2.34.1-1ubuntu1.17_amd64.deb ./tools/install-git.sh
#
set -euo pipefail

# Deliberately NOT $HOME. On the Paperclip runner $HOME is a per-run temp
# directory that is deleted when the run ends; /home/paperclip persists and is
# already on PATH, which is what lets the next heartbeat find the binary.
PREFIX="${PREFIX:-/home/paperclip/.local}"
POOL="${GIT_DEB_POOL:-http://archive.ubuntu.com/ubuntu/pool/main/g/git/}"
PINNED="${GIT_DEB_VERSION:-2.34.1-1ubuntu1.17}"

BIN="$PREFIX/bin"
EXEC_PATH="$PREFIX/libexec/git-core"
TEMPLATE_DIR="$PREFIX/share/git-core/templates"

log() { printf '[install-git] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Already installed?
# ---------------------------------------------------------------------------
# `git` on PATH may be the Paperclip GitHub launcher shim, which searches PATH
# for a real binary and exits 127 with a diagnostic when there is none. So
# probe by running it rather than by testing for the file.
if git --version >/dev/null 2>&1; then
    log "git already works: $(git --version 2>/dev/null | tail -1)"
    exit 0
fi

# ---------------------------------------------------------------------------
# 2. Locate the .deb — cached copy first, then the Ubuntu pool
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/install-git.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

DEB=""
for candidate in \
    "${GIT_DEB_FILE:-}" \
    "$PREFIX/src/git_${PINNED}_amd64.deb" \
    ./git_*.deb \
    "${PAPERCLIP_WORKSPACE_CWD:-/nonexistent}"/git_*.deb
do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
        DEB="$candidate"
        log "using cached package $DEB"
        break
    fi
done

if [ -z "$DEB" ]; then
    DEB="$WORK/git.deb"
    url="${GIT_DEB_URL:-${POOL}git_${PINNED}_amd64.deb}"
    log "downloading $url"
    if ! curl -fsSL --max-time 300 -o "$DEB" "$url"; then
        # The pinned version gets superseded and removed from the pool. Fall
        # back to whatever amd64 git the pool currently carries.
        log "pinned version unavailable, resolving from $POOL"
        url="$(curl -fsSL --max-time 60 "$POOL" \
            | grep -o 'git_2\.[0-9][^"]*_amd64\.deb' \
            | sort -V | tail -1 \
            | sed "s|^|$POOL|")"
        [ -n "$url" ] || { log "FAILED: no git .deb found at $POOL"; exit 1; }
        log "downloading $url"
        curl -fsSL --max-time 300 -o "$DEB" "$url"
    fi
    # Keep it for next time so a re-run does not need the network.
    mkdir -p "$PREFIX/src"
    cp "$DEB" "$PREFIX/src/$(basename "$url")" || true
fi

# ---------------------------------------------------------------------------
# 3. Unpack it with nothing but python3 stdlib (+ a zstd wheel if needed)
# ---------------------------------------------------------------------------
# A .deb is an `ar` archive of debian-binary, control.tar.*, data.tar.*.
# Ubuntu compresses data.tar with zstd, which python 3.10 stdlib cannot read,
# so fetch the zstandard wheel and unzip it (a wheel is a zip file). Debian and
# older Ubuntu use xz, which stdlib handles directly.
log "unpacking into $WORK/root"
DEB="$DEB" WORK="$WORK" python3 - <<'PY'
import io, os, sys, tarfile

deb, work = os.environ['DEB'], os.environ['WORK']
root = os.path.join(work, 'root')
os.makedirs(root, exist_ok=True)

members = {}
with open(deb, 'rb') as f:
    if f.read(8) != b'!<arch>\n':
        sys.exit('not an ar archive: %s' % deb)
    while True:
        header = f.read(60)
        if len(header) < 60:
            break
        name = header[0:16].decode().strip().rstrip('/')
        size = int(header[48:58].decode().strip())
        members[name] = f.read(size)
        if size % 2:
            f.read(1)

data = next((v for k, v in members.items() if k.startswith('data.tar')), None)
name = next(k for k in members if k.startswith('data.tar'))
if data is None:
    sys.exit('no data.tar member in %s' % deb)

if name.endswith('.zst'):
    try:
        import zstandard
    except ImportError:
        import json, urllib.request, zipfile
        tag = 'cp%d%d' % sys.version_info[:2]
        with urllib.request.urlopen(
                'https://pypi.org/pypi/zstandard/0.23.0/json', timeout=60) as r:
            urls = json.load(r)['urls']
        wheel = next(u['url'] for u in urls
                     if tag in u['filename'] and 'manylinux' in u['filename']
                     and 'x86_64' in u['filename'])
        print('[install-git] fetching %s' % wheel.rsplit('/', 1)[-1],
              file=sys.stderr)
        whl = os.path.join(work, 'zstd.whl')
        urllib.request.urlretrieve(wheel, whl)
        lib = os.path.join(work, 'pylib')
        zipfile.ZipFile(whl).extractall(lib)
        sys.path.insert(0, lib)
        import zstandard
    data = zstandard.ZstdDecompressor().stream_reader(io.BytesIO(data)).read()
    mode = 'r:'
elif name.endswith('.xz'):
    mode = 'r:xz'
elif name.endswith('.gz'):
    mode = 'r:gz'
else:
    sys.exit('unsupported compression: %s' % name)

tarfile.open(fileobj=io.BytesIO(data), mode=mode).extractall(root)
print('[install-git] extracted %s' % name, file=sys.stderr)
PY

SRC="$WORK/root/usr"
[ -x "$SRC/bin/git" ] || { log "FAILED: no usr/bin/git in package"; exit 1; }

# ---------------------------------------------------------------------------
# 4. Install
# ---------------------------------------------------------------------------
mkdir -p "$BIN" "$PREFIX/libexec" "$PREFIX/share"
rm -rf "$EXEC_PATH" "$PREFIX/share/git-core"
cp -a "$SRC/lib/git-core" "$EXEC_PATH"
cp -a "$SRC/share/git-core" "$PREFIX/share/git-core"

# Ubuntu's git is built without RUNTIME_PREFIX: it looks for its subcommands in
# the compiled-in /usr/lib/git-core, which does not exist here. A wrapper that
# sets GIT_EXEC_PATH keeps that detail out of every caller's environment.
#
# The wrapper only ever adds the two path variables. It must not touch
# GIT_CONFIG_*, GIT_AUTHOR_*, GIT_COMMITTER_* or the token variables, because
# the Paperclip GitHub launcher injects managed credentials through those and
# this wrapper runs downstream of it.
cat > "$BIN/git" <<EOF
#!/usr/bin/env bash
export GIT_EXEC_PATH="\${GIT_EXEC_PATH:-$EXEC_PATH}"
export GIT_TEMPLATE_DIR="\${GIT_TEMPLATE_DIR:-$TEMPLATE_DIR}"
exec "$EXEC_PATH/git" "\$@"
EOF
chmod 0755 "$BIN/git"

# ---------------------------------------------------------------------------
# 5. Prove it
# ---------------------------------------------------------------------------
version="$("$BIN/git" --version)"
exec_path="$("$BIN/git" --exec-path)"
log "installed $version"
log "exec-path  $exec_path"
[ "$exec_path" = "$EXEC_PATH" ] || { log "FAILED: exec-path not honoured"; exit 1; }

# A real repository operation, not just --version.
#
# Identity goes in the environment, not in `-c user.name`. When the Paperclip
# GitHub launcher cannot resolve a managed credential it exports
# GIT_AUTHOR_NAME="" and GIT_COMMITTER_NAME="", and an empty environment
# variable beats `-c`, so a -c-only commit dies on "empty ident name".
probe="$WORK/probe"
mkdir -p "$probe"
(
    cd "$probe"
    export GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@localhost
    export GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@localhost
    "$BIN/git" init -q .
    : > file
    "$BIN/git" add file
    "$BIN/git" commit -qm probe
    "$BIN/git" log --oneline
) >&2
log "commit probe passed"

case ":$PATH:" in
    *":$BIN:"*) ;;
    *) log "NOTE: $BIN is not on PATH — add it before calling git" ;;
esac

log "done"
