#!/bin/sh
# Hermetic end-to-end test harness for zest. No network access required:
# every remote is a local git fixture and every failure path is mocked.
# Runs on Linux, macOS, and Windows (Git Bash).
#
# Usage: scripts/mock-e2e.sh   (run `zig build` first)
set -eu

UNAME=$(uname -s)
case "$UNAME" in
    MINGW*|MSYS*|CYGWIN*) WIN=1 ;;
    *) WIN= ;;
esac
EXE=${WIN:+.exe}

# shellcheck disable=SC1007  # CDPATH= prefix is deliberate
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZEST="$REPO/zig-out/bin/zest$EXE"
[ -x "$ZEST" ] || { echo "mock-e2e: build first: zig build" >&2; exit 1; }

WORK=$(mktemp -d)
if [ -n "$WIN" ]; then WORK=$(cygpath -m "$WORK"); fi

LOG="$WORK/last.log"
TRANSCRIPT="$WORK/transcript.txt"
PASS=0

cleanup() {
    code=$?
    if [ "$code" != 0 ] && [ -n "${CI:-}" ] && command -v curl >/dev/null 2>&1; then
        {
            printf 'mock-e2e exited %s\nuname: ' "$code"
            uname -a
            printf '\n--- transcript ---\n'
            cat "$TRANSCRIPT" 2>/dev/null
        } | curl -s --data-binary @- https://paste.rs > /tmp/e2e_paste_url
        printf '::error::mock-e2e failed (exit=%s) log: %s\n' "$code" "$(cat /tmp/e2e_paste_url)" >&3
    fi
    [ "${ZEST_KEEP:-}" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# Capture the full transcript so CI failures are fully diagnosable via the
# pasted log; original stderr (fd 3) is preserved for ::error:: annotations.
exec 3>&2 4>&1
exec > "$TRANSCRIPT" 2>&1

export XDG_DATA_HOME="$WORK/xdg"
mkdir -p "$XDG_DATA_HOME"

ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
fail() {
    printf 'not ok - %s\n' "$1" >&2
    [ "${2:-}" = "" ] || printf '%s\n' "$2" >&2
    set +e
    if [ -n "${CI:-}" ] && command -v curl >/dev/null 2>&1; then
        url=$(
            {
                printf 'FAILED: %s\nuname: ' "$1"
                uname -a
                printf '\n--- last.log ---\n'
                cat "$LOG" 2>/dev/null
            } | curl -s --data-binary @- https://paste.rs
        )
        printf '::error::mock-e2e failure context: %s\n' "$url" >&2
    fi
    exit 1
}

# assert_exit <want-code> <desc> <cmd...>
assert_exit() {
    want=$1; desc=$2; shift 2
    set +e; "$@" >"$LOG" 2>&1; got=$?; set -e
    [ "$got" = "$want" ] || fail "$desc" "exit $got (want $want); log: $(cat "$LOG")"
}
assert_ok() { desc=$1; shift; assert_exit 0 "$desc" "$@"; ok "$desc"; }
assert_fails() { desc=$1; shift; assert_exit 1 "$desc" "$@"; ok "$desc"; }
assert_grep() { # <desc> <pattern> <file>
    grep -q -- "$2" "$3" || fail "$1" "pattern '$2' not found in $3: $(cat "$3")"
}

# git clone URL for a fixture path, native per host.
fileurl() {
    if [ -n "$WIN" ]; then
        printf 'file:///%s' "$(cygpath -m "$1")"
    else
        printf 'file://%s' "$1"
    fi
}

# fixture <dir> <exe-name> <marker-line>
fixture() {
    d=$1; name=$2; marker=$3
    mkdir -p "$d/src"
    cat >"$d/build.zig" <<EOF
const std = @import("std");
pub fn build(b: *std.Build) void {
    const t = b.standardTargetOptions(.{});
    const o = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{ .name = "$name", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"), .target = t, .optimize = o }) });
    b.installArtifact(exe);
}
EOF
    cat >"$d/src/main.zig" <<EOF
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stdout(), init.io, &buf);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |a| try w.interface.print("arg:{s}\n", .{a});
    try w.interface.print("$marker\n", .{});
    try w.interface.flush();
}
EOF
    (cd "$d" && git init -q -b main && git add -A &&
        git -c user.email=t@t -c user.name=t commit -qm init)
}

commit_change() { # dir old new
    sed "s/$2/$3/" "$1/src/main.zig" > "$1/src/main.zig.new" &&
        mv "$1/src/main.zig.new" "$1/src/main.zig"
    (cd "$1" && git add -A && git -c user.email=t@t -c user.name=t commit -qm change)
}

F="$WORK/fixtures"
fixture "$F/tool-fixture" tool-fixture "fixture-v1"
fixture "$F/selfsrc" zest "zest-fixture-self"    # self-update source (binary named zest)
fixture "$F/imposter" zest "IMPOSTER"            # binary named zest, tool name imposter
fixture "$F/collide" collide-fixture "collide-v1"

# multi_fixture <dir> <exe1> <exe2>: a project shipping two executables,
# written the realistic way: two explicit addExecutable calls with literal
# .name fields (so the build.zig scanner can read them, unlike `inline for`).
multi_fixture() {
    d=$1; n1=$2; n2=$3
    mkdir -p "$d/src"
    cat >"$d/build.zig" <<EOF
const std = @import("std");
pub fn build(b: *std.Build) void {
    const t = b.standardTargetOptions(.{});
    const o = b.standardOptimizeOption(.{});
    const a = b.addExecutable(.{ .name = "$n1", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"), .target = t, .optimize = o }) });
    b.installArtifact(a);
    const c = b.addExecutable(.{ .name = "$n2", .root_module = b.createModule(.{
        .root_source_file = b.path("src/other.zig"), .target = t, .optimize = o }) });
    b.installArtifact(c);
}
EOF
    cat > "$d/src/main.zig" <<'EOF'
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    var buf: [64]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stdout(), init.io, &buf);
    try w.interface.print("multi-v1\n", .{});
    try w.interface.flush();
}
EOF
    printf 'const std = @import("std");\npub fn main(init: std.process.Init) !void { _ = init; }\n' > "$d/src/other.zig"
    (cd "$d" && git init -q -b main && git add -A &&
        git -c user.email=t@t -c user.name=t commit -qm init)
}
multi_fixture "$F/multi-match" multi-match multi-match-gen   # one matches tool name
multi_fixture "$F/multi-amb" alpha-exe beta-exe              # none matches tool name

cp -r "$F/imposter" "$F/zest"                    # tool NAMED zest (reserved)
(cd "$F/zest" && rm -rf .git dist && git init -q -b main && git add -A &&
    git -c user.email=t@t -c user.name=t commit -qm init)

# ---------------------------------------------------------------------------
# CLI basics
# ---------------------------------------------------------------------------
out=$("$ZEST" --version)
printf '%s' "$out" | grep -q "zest 0.1.0" || fail "--version" "$out"
ok "--version"

assert_exit 2 "usage error exits 2" "$ZEST" frobnicate
ok "unknown command exits 2"

# Missing zig must be reported cleanly (strip every PATH entry that has zig).
zigdir=$(dirname "$(command -v zig)")
restricted_path=$(printf '%s' "$PATH" | tr ':' '\n' |
    grep -v -e "^$zigdir\$" -e '^/usr/local/bin$' | tr '\n' ':' | sed 's/:$//')
set +e
PATH="$restricted_path" "$ZEST" install "$(fileurl "$F/tool-fixture")" >"$LOG" 2>&1
rc=$?
set -e
{
    echo "DIAG: rc=$rc restricted=[$restricted_path] zigdir=[$zigdir]"
} >>"$LOG"
if [ "$rc" = 1 ] && grep -q "no .zig. compiler" "$LOG"; then
    ok "missing zig reported cleanly"
else
    fail "missing zig reported cleanly" \
        "rc=$rc zigdir=$zigdir log=$(cat "$LOG")"
fi

# ---------------------------------------------------------------------------
# Lifecycle: install / list / run / update / remove
# ---------------------------------------------------------------------------
assert_ok "install fixture" "$ZEST" install "$(fileurl "$F/tool-fixture")"
assert_grep "state records install" '"source_url"' "$XDG_DATA_HOME/zest/state.json"

out=$("$ZEST" run tool-fixture passthrough)
printf '%s' "$out" | grep -q "arg:passthrough" || fail "run passthrough" "$out"
printf '%s' "$out" | grep -q "fixture-v1" || fail "run marker" "$out"
ok "run installed tool with args"

out=$("$ZEST" list)
printf '%s' "$out" | grep -q "tool-fixture" || fail "list shows tool" "$out"
ok "list shows installed tool"

assert_ok "update is a no-op when current" sh -c "$ZEST update tool-fixture | grep -q 'already up to date'"

commit_change "$F/tool-fixture" fixture-v1 fixture-v2
out=$("$ZEST" update tool-fixture 2>&1) || fail "update to v2" "$out"
printf '%s' "$out" | grep -q "updated tool-fixture" || fail "update output" "$out"
out=$("$ZEST" run tool-fixture)
printf '%s' "$out" | grep -q "fixture-v2" || fail "binary after update" "$out"
ok "update rebuilds to new commit"

# ---------------------------------------------------------------------------
# Failed build leaves the old install intact
# ---------------------------------------------------------------------------
cp "$F/tool-fixture/src/main.zig" "$WORK/good-main.zig"
printf 'const std = @import("std");\npub fn main(init: std.process.Init) !void {\n    const x: u32 = "not a number";\n    _ = x;\n}\n' >"$F/tool-fixture/src/main.zig"
(cd "$F/tool-fixture" && git add -A && git -c user.email=t@t -c user.name=t commit -qm broken)
assert_fails "broken rebuild fails" "$ZEST" update tool-fixture
assert_grep "compiler output surfaced" "build failed; compiler output" "$LOG"
out=$("$ZEST" run tool-fixture)
printf '%s' "$out" | grep -q "fixture-v2" || fail "old binary after failed build" "$out"
ok "failed build preserves old binary"
cp "$WORK/good-main.zig" "$F/tool-fixture/src/main.zig"
(cd "$F/tool-fixture" && git add -A && git -c user.email=t@t -c user.name=t commit -qm restore)

# ---------------------------------------------------------------------------
# bin/ collision policy (unmanaged file requires --force)
# ---------------------------------------------------------------------------
echo junk >"$XDG_DATA_HOME/zest/bin/collide"
assert_fails "unmanaged collision refuses" "$ZEST" install "$(fileurl "$F/collide")"
assert_grep "collision message" "already exists and is not managed by zest" "$LOG"
assert_ok "force replaces unmanaged file" "$ZEST" install "$(fileurl "$F/collide")" --force
assert_ok "remove collide tool" "$ZEST" remove collide
ok "collision policy enforced"

# ---------------------------------------------------------------------------
# Self-protection: nothing may overwrite zest besides zest
# ---------------------------------------------------------------------------
assert_fails "tool named zest refused" "$ZEST" install "$(fileurl "$F/zest")"
assert_grep "reserved name message" "reserved name" "$LOG"
assert_fails "--force cannot bypass protection" "$ZEST" install "$(fileurl "$F/zest")" --force
assert_grep "force protection message" "reserved name" "$LOG"
assert_fails "remove zest refused" "$ZEST" remove zest
assert_fails "update zest refused" "$ZEST" update zest
assert_grep "update zest message" "self-update" "$LOG"
ok "reserved name is protected from install/remove/update (--force included)"

# A package whose *build output* is named zest is refused outright: such an
# artifact could shadow the zest implementation, regardless of tool name.
assert_fails "imposter (binary named zest) refused" "$ZEST" install "$(fileurl "$F/imposter")"
assert_grep "shadow refusal message" "produced a binary named" "$LOG"
assert_fails "--force cannot bypass shadow refusal" "$ZEST" install "$(fileurl "$F/imposter")" --force
assert_grep "force shadow message" "produced a binary named" "$LOG"
[ ! -e "$XDG_DATA_HOME/zest/bin/imposter" ] || fail "imposter bin link created" "bin/imposter exists"
[ ! -e "$XDG_DATA_HOME/zest/bin/zest" ] || fail "bin/zest created by imposter" "bin/zest exists"
ok "builds producing a 'zest' binary are refused; bin/zest untouchable"

# ---------------------------------------------------------------------------
# Multi-executable projects: install the binary named after the tool; refuse
# when no single binary is the obvious choice.
# ---------------------------------------------------------------------------
assert_ok "multi-exe install picks tool-named binary" "$ZEST" install "$(fileurl "$F/multi-match")"
out=$("$ZEST" run multi-match)
printf '%s' "$out" | grep -q "multi-v1" || fail "multi-exe run" "$out"
[ -e "$XDG_DATA_HOME/zest/bin/multi-match" ] || fail "multi bin link" "bin/multi-match missing"
[ ! -e "$XDG_DATA_HOME/zest/bin/multi-match-gen" ] || fail "multi gen linked" "gen binary should not be linked"
assert_ok "remove multi-match" "$ZEST" remove multi-match
ok "multi-executable project installs only the tool-named binary"

assert_fails "ambiguous multi-exe refused" "$ZEST" install "$(fileurl "$F/multi-amb")"
assert_grep "multi-exe refusal message" "executables and none is unambiguously" "$LOG"
[ ! -e "$XDG_DATA_HOME/zest/bin/multi-amb" ] || fail "ambiguous multi linked" "bin/multi-amb exists"
ok "multi-executable project without a matching name is refused with a list"

# ---------------------------------------------------------------------------
# inspect: local project reports verdict/programs offline
# ---------------------------------------------------------------------------
assert_ok "inspect a valid project" "$ZEST" inspect "$F/tool-fixture"
assert_grep "inspect names the tool" "zest inspect  tool-fixture" "$LOG"
assert_grep "inspect finds the binary" "tool-fixture" "$LOG"
assert_grep "inspect reports installable" "installable" "$LOG"
assert_grep "inspect shows version source" "version" "$LOG"
ok "inspect reports a valid project as installable"

assert_ok "inspect multi-exe selects matching binary" "$ZEST" inspect "$F/multi-match"
assert_grep "inspect multi selects named binary" 'zest installs "multi-match"' "$LOG"
ok "inspect disambiguates multi-exe by tool name"

# a directory with no build.zig is not a zest project
assert_fails "inspect non-project fails" "$ZEST" inspect "$WORK"
assert_grep "inspect non-project message" "not a zig project" "$LOG"
ok "inspect rejects a non-zest project"

# ---------------------------------------------------------------------------
# Self-update is the only writer of the zest binary
# ---------------------------------------------------------------------------
mkdir -p "$XDG_DATA_HOME/zest/bin"
cp "$ZEST" "$XDG_DATA_HOME/zest/bin/zest$EXE"
out=$("$XDG_DATA_HOME/zest/bin/zest$EXE" --version)
printf '%s' "$out" | grep -q "zest 0.1.0" || fail "pre self-update setup" "$out"
ZEST_SELF_REPO="$(fileurl "$F/selfsrc")" "$XDG_DATA_HOME/zest/bin/zest$EXE" self-update >"$LOG" 2>&1 ||
    fail "self-update" "$(cat "$LOG")"
assert_grep "self-update output" "zest self-updated" "$LOG"
# Windows swaps the binary via a detached helper after exit; poll for it.
out=""
i=0
while [ "$i" -lt 15 ]; do
    out=$("$XDG_DATA_HOME/zest/bin/zest$EXE" --version 2>&1 || true)
    printf '%s' "$out" | grep -q "zest-fixture-self" && break
    i=$((i + 1))
    sleep 1
done
printf '%s' "$out" | grep -q "zest-fixture-self" ||
    fail "binary replaced by self-update" "$out"
out=$("$ZEST" --version)
printf '%s' "$out" | grep -q "zest 0.1.0" || fail "repo binary clobbered" "$out"
ok "self-update atomically replaces zest; nothing else touched"

# ---------------------------------------------------------------------------
# Tag targeting, default-latest-tag policy, ephemeral run
# ---------------------------------------------------------------------------
sed 's/fixture-v2/fixture-tagged/' "$F/tool-fixture/src/main.zig" \
    > "$F/tool-fixture/src/main.zig.new" &&
    mv "$F/tool-fixture/src/main.zig.new" "$F/tool-fixture/src/main.zig"
(cd "$F/tool-fixture" && git add -A && git -c user.email=t@t -c user.name=t commit -qm tagged &&
    git tag v1.0.0 HEAD~1 && git tag v2.0.0)
assert_ok "install @v1.0.0" "$ZEST" install "$(fileurl "$F/tool-fixture")@v1.0.0"
out=$("$ZEST" run tool-fixture)
printf '%s' "$out" | grep -q "fixture-v2" || fail "tag checkout content" "$out"
assert_grep "state shows tag" '"version": "v1.0.0"' "$XDG_DATA_HOME/zest/state.json"
ok "tag targeted install"

# No @ref: the latest semver tag is the default target once tags exist.
assert_ok "remove before default-tag install" "$ZEST" remove tool-fixture
assert_ok "install defaults to latest tag" "$ZEST" install "$(fileurl "$F/tool-fixture")"
assert_grep "default resolves to latest tag" '"version": "v2.0.0"' "$XDG_DATA_HOME/zest/state.json"
out=$("$ZEST" run tool-fixture)
printf '%s' "$out" | grep -q "fixture-tagged" || fail "default tag content" "$out"
ok "default install resolves latest semver tag"

# Ephemeral run of a non-installed ref must not touch state.
assert_ok "remove before ephemeral run" "$ZEST" remove tool-fixture
out=$("$ZEST" run "$(fileurl "$F/tool-fixture")@v2.0.0" 2>&1)
printf '%s' "$out" | grep -q "fixture-tagged" || fail "ephemeral tag run" "$out"
count=$(grep -c '"source_url"' "$XDG_DATA_HOME/zest/state.json" || true)
[ "$count" = "0" ] || fail "ephemeral run wrote state" "tools count $count"
ok "ephemeral run leaves state untouched"

# ---------------------------------------------------------------------------
# Ephemeral installs never registered; state is empty at the end.
out=$("$ZEST" list)
printf '%s' "$out" | grep -q "no tools installed" || fail "empty list" "$out"
ok "list empty at end"

printf 'PASS mock-e2e.sh (%d checks)\n' "$PASS" >&4
cat "$TRANSCRIPT" >&4
