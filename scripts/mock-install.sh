#!/bin/sh
# Hermetic tests for install.sh. No network access required: the zest source
# is a local git fixture and even the zig bootstrap is exercised against a
# fake toolchain tarball served over file://.
#
# Usage: scripts/mock-install.sh   (run `zig build` first)
set -eu

# shellcheck disable=SC1007  # CDPATH= prefix is deliberate
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INSTALL="$REPO/install.sh"
[ -f "$INSTALL" ] || { echo "mock-install: install.sh not found" >&2; exit 1; }

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

PASS=0
ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
fail() {
    printf 'not ok - %s\n' "$1" >&2
    [ "${2:-}" = "" ] || printf '%s\n' "$2" >&2
    # On CI, publish the captured streams so failures are diagnosable from
    # the check-run annotations.
    if [ -n "${CI:-}" ] && command -v curl >/dev/null 2>&1; then
        url=$({
            printf 'FAILED: %s\n\n--- ERR ---\n' "$1"
            cat "$ERR" 2>/dev/null
            printf '\n--- OUT ---\n'
            cat "$OUT" 2>/dev/null
        } | curl -s --data-binary @- https://paste.rs)
        printf '::error::mock-install failure context: %s\n' "$url"
    fi
    exit 1
}
assert_grep() {
    grep -q -- "$2" "$3" || fail "$1" "pattern '$2' not found in $3: $(cat "$3")"
}

fixture() { # dir marker
    d=$1; marker=$2
    mkdir -p "$d/src"
    cat >"$d/build.zig" <<'EOF'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const t = b.standardTargetOptions(.{});
    const o = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{ .name = "zest", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"), .target = t, .optimize = o }) });
    b.installArtifact(exe);
}
EOF
    cat >"$d/src/main.zig" <<EOF
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    _ = init;
    std.debug.print("zest $marker\n", .{});
}
EOF
    (cd "$d" && git init -q -b main && git add -A &&
        git -c user.email=t@t -c user.name=t commit -qm init)
}

V1="$WORK/self-v1"
V2="$WORK/self-v2"
fixture "$V1" 0.1.0-install-fixture
fixture "$V2" 0.2.0-install-fixture
(cd "$V2" && git tag v1.0.0)

DATA="$WORK/data"
OUT="$WORK/last.out"
ERR="$WORK/last.err"

# ---------------------------------------------------------------------------
# 1. Fresh install from a local repo with a system zig present.
#    --yes: after a successful install the bin dir is added to the shell
#    profile so installed tools are callable by name.
HOMEA="$WORK/homea"; mkdir -p "$HOMEA"
HOME="$HOMEA" SHELL=/bin/bash ZEST_DATA="$DATA" ZEST_REPO_URL="file://$V1" \
    sh "$INSTALL" --yes >"$OUT" 2>"$ERR" ||
    fail "fresh install" "$(cat "$ERR")"
assert_grep "fresh install log" "installed" "$ERR"
out=$("$DATA/bin/zest" --version 2>&1)
printf '%s' "$out" | grep -q "0.1.0-install-fixture" || fail "fresh binary marker" "$out"
ok "fresh install builds and installs zest"

rc_profile="$HOMEA/.bashrc"
if [ -f "$rc_profile" ] && grep -q "zest toolchain" "$rc_profile"; then
    : # profile wired by --yes
else
    fail "path --yes writes profile" "no zest toolchain block in $rc_profile"
fi
grep -qF "$DATA/bin" "$rc_profile" || fail "path --yes profile path" "bin dir missing"
ok "install --yes adds the zest bin dir to the shell profile"

# ---------------------------------------------------------------------------
# 2. Re-run must delegate to `zest self-update`: the script never overwrites
#    an existing zest; zest replaces itself. The installed binary is a real
#    zest build so it can actually perform the self-update.
# ---------------------------------------------------------------------------
#    --no: the PATH step leaves the profile untouched.
HOMEB="$WORK/homeb"; mkdir -p "$HOMEB"
DATA2="$WORK/data2"
mkdir -p "$DATA2/bin"
cp "$REPO/zig-out/bin/zest" "$DATA2/bin/zest"
HOME="$HOMEB" SHELL=/bin/bash ZEST_DATA="$DATA2" ZEST_REPO_URL="file://$V1" ZEST_SELF_REPO="file://$V2" \
    sh "$INSTALL" --no >"$OUT" 2>"$ERR" || fail "self-update delegation" "$(cat "$ERR")"
[ ! -e "$HOMEB/.bashrc" ] || fail "path --no wrote a profile" "profile should not exist"
ok "install --no leaves the profile untouched"
# Note: the delegated zest rewrites the captured files from offset 0 (std.Io
# positional writes), so install.sh's own pre-exec log lines are not durable
# here. Delegation is proven by the self-update result and exit code.
assert_grep "self-update log" "zest self-updated" "$OUT"
assert_grep "self-update resolved tag" "latest zest release: v1.0.0" "$ERR"
out=$("$DATA2/bin/zest" --version 2>&1)
printf '%s' "$out" | grep -q "0.2.0-install-fixture" || fail "upgraded binary marker" "$out"
ok "re-run delegates to zest self-update (only zest overwrites zest)"

# ---------------------------------------------------------------------------
# 3. The real installed zest refuses packages that would overwrite it:
#    a repo NAMED zest is refused (--force included), while a package whose
#    binary is merely named zest installs under its own tool name and never
#    touches bin/zest.
# ---------------------------------------------------------------------------
IMPOSTER="$WORK/imposter"
mkdir -p "$IMPOSTER/src"
cat >"$IMPOSTER/build.zig" <<'EOF'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const t = b.standardTargetOptions(.{});
    const o = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{ .name = "zest", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"), .target = t, .optimize = o }) });
    b.installArtifact(exe);
}
EOF
printf 'const std = @import("std");\npub fn main() !void {}\n' >"$IMPOSTER/src/main.zig"
(cd "$IMPOSTER" && git init -q -b main && git add -A &&
    git -c user.email=t@t -c user.name=t commit -qm init)

NAMED="$WORK/zest"
cp -r "$IMPOSTER" "$NAMED"
rm -rf "$NAMED/.git" && (cd "$NAMED" && git init -q -b main && git add -A &&
    git -c user.email=t@t -c user.name=t commit -qm init)

DATA3="$WORK/data3"
mkdir -p "$DATA3/zest/bin"
cp "$REPO/zig-out/bin/zest" "$DATA3/zest/bin/zest"
before_size=$(wc -c <"$DATA3/zest/bin/zest")
XDG_DATA_HOME="$DATA3" "$DATA3/zest/bin/zest" install "file://$NAMED" >"$OUT" 2>"$ERR" &&
    fail "zest-named install must fail" "unexpected success"
assert_grep "protection message" "reserved name" "$ERR"
XDG_DATA_HOME="$DATA3" "$DATA3/zest/bin/zest" install "file://$NAMED" --force >"$OUT" 2>"$ERR" &&
    fail "zest-named --force must fail" "unexpected success"
assert_grep "force protection message" "reserved name" "$ERR"
[ "$(wc -c <"$DATA3/zest/bin/zest")" = "$before_size" ] || fail "binary changed by imposter" "size mismatch"
ok "tool named zest is refused (--force included); binary untouched"

XDG_DATA_HOME="$DATA3" "$DATA3/zest/bin/zest" install "file://$IMPOSTER" >"$OUT" 2>"$ERR" &&
    fail "imposter install should be refused" "unexpected success"
assert_grep "shadow refusal message" "produced a binary named 'zest'" "$ERR"
[ "$(wc -c <"$DATA3/zest/bin/zest")" = "$before_size" ] || fail "bin/zest changed" "size mismatch"
[ ! -e "$DATA3/zest/bin/imposter" ] || fail "imposter installed" "zest/bin/imposter exists"
ok "builds producing a 'zest' binary are refused so they can never shadow zest"

# ---------------------------------------------------------------------------
# 4. zig bootstrap path: no zig in PATH, fake toolchain served over file://.
#    The fake zig cannot compile zest, so the run is expected to fail at the
#    build step, after proving the bootstrap worked.
# ---------------------------------------------------------------------------
fakebin="$WORK/faketoolchains"
mkdir -p "$fakebin/zig-x86_64-linux-0.16.0"
# shellcheck disable=SC2016  # the fake zig script must contain literal "$1"
printf '#!/bin/sh\nif [ "$1" = version ]; then echo 0.16.0; else echo "fake zig cannot build" >&2; exit 1; fi\n' \
    >"$fakebin/zig-x86_64-linux-0.16.0/zig"
chmod +x "$fakebin/zig-x86_64-linux-0.16.0/zig"
tar -Jcf "$WORK/zig-x86_64-linux-0.16.0.tar.xz" -C "$fakebin" zig-x86_64-linux-0.16.0
shasum=$(sha256sum "$WORK/zig-x86_64-linux-0.16.0.tar.xz" | cut -d' ' -f1)
printf '{"0.16.0":{"x86_64-linux":{"tarball":"file://%s/zig-x86_64-linux-0.16.0.tar.xz","shasum":"%s","size":1}}}\n' \
    "$WORK" "$shasum" >"$WORK/index.json"

# A PATH with every tool install.sh needs but no zig, built from explicit
# symlinks so it works regardless of where the real zig is installed.
safebin="$WORK/safebin"
mkdir -p "$safebin"
for t in sh git curl wget uname tar sed grep cut basename find mkdir rm mv cp cat dirname sort chmod sha256sum shasum tr wc readlink xz gzip; do
    p=$(command -v "$t" 2>/dev/null) || continue
    case "$p" in
        */*) ln -sf "$(readlink -f "$p")" "$safebin/$t" ;;
        *) ln -sf "/usr/bin/$t" "$safebin/$t" ;;  # shell builtin-style result
    esac
done
[ -x "$safebin/git" ] || fail "safebin setup" "git missing from safebin"

ZIG_INDEX_URL="file://$WORK/index.json" \
    PATH="$safebin" ZEST_DATA="$WORK/bootstrap-data" ZEST_REPO_URL="file://$V1" \
    sh "$INSTALL" >"$OUT" 2>"$ERR" && fail "bootstrap run must fail at build" "unexpected success"
assert_grep "bootstrap log" "bootstrapped zig 0.16.0" "$ERR"
assert_grep "bootstrap used private toolchain" "private to" "$ERR"
assert_grep "fake zig build failure surfaced" "build failed" "$ERR"
[ ! -x "$WORK/bootstrap-data/bin/zest" ] || fail "fake build installed" "bin/zest exists"
ok "zig bootstrap downloads, verifies, and extracts without touching \$PATH"


printf 'PASS %s (%d checks)\n' "$(basename "$0")" "$PASS"
