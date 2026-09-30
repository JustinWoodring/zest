#!/bin/sh
# zest bootstrap installer for https://github.com/JustinWoodring/zest
#
#   curl -fsSL https://justinwoodring.github.io/zest/install.sh | sh
#
# What it does:
#   0. If zest is already installed, hand over to `zest self-update`, which is the only
#      zest itself may overwrite the zest binary; this script never does.
#   1. Use a system zig >= $ZIG_VERSION, or bootstrap a private toolchain
#      under $ZEST_DATA/toolchains (checksum-verified, no root required).
#   2. Clone zest and build it in ReleaseSafe with the native zig build
#      pipeline.
#   3. Atomically install the binary at $ZEST_DATA/bin/zest.
#
#   4. Offer to add $ZEST_DATA/bin to PATH so `zest` and every tool it
#      installs are callable by name. Interactive by default; use --yes /
#      --no-path to answer up front for automation.
#
# Usage: install.sh [-y|--yes] [-n|--no-path]
#
# Environment overrides:
#   ZEST_REPO_URL   git URL to build zest from (default: canonical repo)
#   ZEST_REF        branch/tag to build (default: default branch)
#   ZIG_VERSION     minimum/bootstrapped zig version (default: 0.16.0)
#   ZIG_INDEX_URL   ziglang download index (default: official)
#   ZEST_DATA       state root (default: $XDG_DATA_HOME/zest or
#                   ~/.local/share/zest)
set -eu

ZEST_REPO_URL="${ZEST_REPO_URL:-https://github.com/JustinWoodring/zest}"
ZEST_REF="${ZEST_REF:-}"
ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
ZIG_INDEX_URL="${ZIG_INDEX_URL:-https://ziglang.org/download/index.json}"
ZEST_DATA="${ZEST_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/zest}"
# zest derives its layout from XDG_DATA_HOME; keep its view of the data root
# consistent with ZEST_DATA for everything this script invokes (including the
# delegated `zest self-update`).
XDG_DATA_HOME="$(dirname "$ZEST_DATA")"
export XDG_DATA_HOME
ZEST_BIN="$ZEST_DATA/bin/zest"

log() { printf 'zest-install: %s\n' "$*" >&2; }
die() { printf 'zest-install: error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

fetch() { # fetch <url> <outfile>
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$2" "$1"
    else
        die "need curl or wget to download files"
    fi
}

# ---------------------------------------------------------------------------
# 0. Existing zest wins: only zest may overwrite zest.
# ---------------------------------------------------------------------------
if [ -x "$ZEST_BIN" ]; then
    log "found existing zest at $ZEST_BIN; delegating upgrade to zest itself"
    exec "$ZEST_BIN" self-update
fi

need git

# ---------------------------------------------------------------------------
# 1. zig: system toolchain if new enough, else a private bootstrapped copy.
# ---------------------------------------------------------------------------
ZIG=""
zig_ok() {
    command -v zig >/dev/null 2>&1 || return 1
    v=$(zig version 2>/dev/null) || return 1
    lowest=$(printf '%s\n%s\n' "$v" "$ZIG_VERSION" | sort -V | sed -n 1p)
    [ "$lowest" = "$ZIG_VERSION" ]
}

if zig_ok; then
    ZIG=zig
    log "using system zig $(zig version)"
else
    need uname
    need tar
    os=$(uname -s)
    arch=$(uname -m)
    case "$os" in
        Linux) zos=linux ;;
        Darwin) zos=macos ;;
        *) die "unsupported OS: $os (install zig $ZIG_VERSION manually)" ;;
    esac
    case "$arch" in
        x86_64) zarch=x86_64 ;;
        aarch64 | arm64) zarch=aarch64 ;;
        x86) zarch=x86 ;;
        *) die "unsupported architecture: $arch (install zig $ZIG_VERSION manually)" ;;
    esac

    key="$zarch-$zos"
    mkdir -p "$ZEST_DATA/toolchains"
    index="$ZEST_DATA/toolchains/index.json"
    log "no zig >= $ZIG_VERSION in \$PATH; bootstrapping zig $ZIG_VERSION ($key)"
    fetch "$ZIG_INDEX_URL" "$index"

    minified=$(tr -d ' \t\r\n' < "$index")
    # The tarball filename pins the version, and "shasum" directly follows
    # "tarball" inside each flat arch-os entry of the index.
    pair=$(printf '%s\n' "$minified" | grep -o "\"tarball\":\"[^\"]*zig-$key-$ZIG_VERSION\.tar\.xz\",\"shasum\":\"[0-9a-f]\{64\}\"" | sed -n 1p) ||
        die "zig $ZIG_VERSION ($key) not found in $ZIG_INDEX_URL; install zig manually and re-run"
    tarball=$(printf '%s\n' "$pair" | sed -n 's/.*"tarball":"\([^"]*\)".*/\1/p')
    shasum=$(printf '%s\n' "$pair" | sed -n 's/.*"shasum":"\([0-9a-f]*\)".*/\1/p')
    if [ -z "$tarball" ] || [ -z "$shasum" ]; then
        die "could not parse the zig download index; install zig manually and re-run"
    fi

    archive="$ZEST_DATA/toolchains/$(basename "$tarball")"
    fetch "$tarball" "$archive"

    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$archive" | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$archive" | cut -d' ' -f1)
    else
        die "need sha256sum or shasum to verify the zig download"
    fi
    [ "$actual" = "$shasum" ] ||
        die "zig tarball checksum mismatch (want $shasum, got $actual)"

    tar -xf "$archive" -C "$ZEST_DATA/toolchains" ||
        die "could not extract $archive (is xz installed?)"
    rm -f "$archive"

    ZIG="$ZEST_DATA/toolchains/zig-$key-$ZIG_VERSION/zig"
    [ -x "$ZIG" ] || ZIG=$(find "$ZEST_DATA/toolchains" -maxdepth 2 -type f -name zig | sed -n 1p)
    if [ -z "$ZIG" ] || [ ! -x "$ZIG" ]; then
        die "bootstrapped zig not found after extraction"
    fi
    log "bootstrapped zig $("$ZIG" version) at $ZIG (private to $ZEST_DATA)"
fi

# ---------------------------------------------------------------------------
# 2. Clone + build zest (ReleaseSafe, native zig build pipeline).
# ---------------------------------------------------------------------------
src="$ZEST_DATA/self/src"
if [ -d "$src/.git" ]; then
    log "updating zest source at $src"
    if [ -n "$ZEST_REF" ]; then
        git -C "$src" fetch --quiet --depth 1 --force --tags origin "$ZEST_REF" ||
            die "could not fetch $ZEST_REF from $ZEST_REPO_URL"
    else
        git -C "$src" fetch --quiet --depth 1 --force origin HEAD ||
            die "could not fetch zest source from $ZEST_REPO_URL"
    fi
    git -C "$src" checkout --quiet --force --detach FETCH_HEAD ||
        die "could not check out the zest source"
    git -C "$src" reset --quiet --hard FETCH_HEAD ||
        die "could not reset the zest source"
else
    rm -rf "$src"
    log "cloning $ZEST_REPO_URL → $src"
    if [ -n "$ZEST_REF" ]; then
        git clone --quiet --depth 1 -b "$ZEST_REF" "$ZEST_REPO_URL" "$src" ||
            die "could not clone $ZEST_REPO_URL ($ZEST_REF)"
    else
        git clone --quiet --depth 1 "$ZEST_REPO_URL" "$src" ||
            die "could not clone $ZEST_REPO_URL"
    fi
fi

log "building zest (ReleaseSafe) with zig build"
(cd "$src" && "$ZIG" build -p dist -Doptimize=ReleaseSafe --summary none) ||
    die "zest build failed"

new_bin="$src/dist/bin/zest"
[ -x "$new_bin" ] || die "build did not produce dist/bin/zest"

# ---------------------------------------------------------------------------
# 3. Atomic install into $ZEST_DATA/bin. We only get here when $ZEST_BIN did
#    not exist (step 0), so this is a fresh install, never an overwrite.
# ---------------------------------------------------------------------------
mkdir -p "$ZEST_DATA/bin"
tmp="$ZEST_DATA/bin/.zest.tmp.$$"
cat "$new_bin" > "$tmp"
chmod 755 "$tmp"
mv -f "$tmp" "$ZEST_BIN"

log "installed $ZEST_BIN ($("$ZEST_BIN" --version 2>/dev/null | sed -n 1p))"

# ---------------------------------------------------------------------------
# 4. PATH. The bin dir holds zest itself and every tool zest installs, so
#    adding it once makes `zest`, `mytool`, etc. callable by name.
#    Prompt interactively; --yes / --no-path answer for automation.
# ---------------------------------------------------------------------------
PATH_DECISION=ask
for arg in "$@"; do
    case "$arg" in
        -y|--yes) PATH_DECISION=yes ;;
        -n|--no|--no-path) PATH_DECISION=no ;;
        -h|--help)
            cat <<'USAGE'
usage: install.sh [-y|--yes] [-n|--no-path]
  -y, --yes     add the zest bin dir to PATH without prompting
  -n, --no      do not touch PATH
With neither flag, the installer asks before editing your shell profile.
USAGE
            exit 0
            ;;
    esac
done

on_path() { case ":$PATH:" in *":$1:"*) return 0 ;; esac; return 1; }

shell_rc_for() {
    # Best-match startup file for the user's shell.
    case "$(basename "${SHELL:-/bin/sh}")" in
        zsh) printf '%s\n' "$HOME/.zshrc" ;;
        bash) printf '%s\n' "$HOME/.bashrc" ;;
        *) printf '%s\n' "$HOME/.profile" ;;
    esac
}

persist_path() {
    rc="$(shell_rc_for)"
    line="export PATH=\"$ZEST_DATA/bin:\$PATH\""
    if grep -qsF "$ZEST_DATA/bin" "$rc" 2>/dev/null; then
        log "$rc already references $ZEST_DATA/bin"
    else
        printf '\n# zest toolchain\n%s\n' "$line" >> "$rc"
        log "added $ZEST_DATA/bin to PATH via $rc"
    fi
    log "restart your shell (or 'source $rc') to use it now"
}

if on_path "$ZEST_DATA/bin"; then
    log "$ZEST_DATA/bin is already on your PATH; 'zest' and installed tools are callable by name"
elif [ "$PATH_DECISION" = yes ]; then
    persist_path
elif [ "$PATH_DECISION" = no ]; then
    log "skipping PATH; add $ZEST_DATA/bin yourself or run tools with 'zest run'"
elif [ -t 0 ]; then
    printf 'Add %s to your PATH so `zest` and installed tools run by name? [Y/n] ' "$ZEST_DATA/bin" >&2
    read -r answer || answer=n
    case "$answer" in
        n|N|no|No) log "skipping PATH; run tools with 'zest run'" ;;
        *) persist_path ;;
    esac
else
    # Non-interactive without a flag (CI, pipes): don't block, just advise.
    log "$ZEST_DATA/bin is not on your PATH; add it, or re-run with --yes to do it automatically"
fi

log "done; upgrade any time with: zest self-update (or re-run this script)"
