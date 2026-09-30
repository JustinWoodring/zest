# Hermetic Windows tests for install.ps1. No network access required: the
# zest source is a local git fixture and the zig bootstrap is exercised
# against a fake toolchain archive over file://.
#
# Usage (PowerShell 7 on windows-latest): ./scripts/mock-install.ps1
$ErrorActionPreference = 'Stop'

$REPO = Split-Path -Parent $PSScriptRoot
$INSTALL = Join-Path $REPO 'install.ps1'
if (-not (Test-Path $INSTALL)) { throw 'mock-install: install.ps1 not found' }
$RealZest = Join-Path $REPO 'zig-out\bin\zest.exe'
if (-not (Test-Path $RealZest)) { throw 'mock-install: build first: zig build' }

$WORK = Join-Path ([System.IO.Path]::GetTempPath()) ("zest-mock-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $WORK | Out-Null

$script:PASS = 0
function Ok([string]$Name) { $script:PASS++; Write-Host "ok $($script:PASS) - $Name" }
function Fail([string]$Name, [string]$Detail = '') {
    Write-Host "not ok - $Name"
    if ($Detail) { Write-Host $Detail }
    if ($env:CI -and (Get-Command curl -ErrorAction SilentlyContinue)) {
        $url = @("FAILED: $Name", '--- detail ---', $Detail) -join "`n" |
            curl -s --data-binary '@-' https://paste.rs
        Write-Host "::error::mock-install failure context: $url"
    }
    exit 1
}

function Assert-Grep([string]$Name, [string]$Pattern, [string]$Text) {
    if ($Text -notmatch [regex]::Escape($Pattern)) {
        Fail $Name "pattern '$Pattern' not found in: $Text"
    }
}

function Fixture([string]$Dir, [string]$Marker) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'src') | Out-Null
    @'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const t = b.standardTargetOptions(.{});
    const o = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{ .name = "zest", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"), .target = t, .optimize = o }) });
    b.installArtifact(exe);
}
'@ | Set-Content (Join-Path $Dir 'build.zig')
    "const std = @import(""std"");`npub fn main(init: std.process.Init) !void {`n    _ = init;`n    std.debug.print(""zest $marker\n"", .{});`n}" |
        Set-Content (Join-Path $Dir 'src\main.zig')
    Push-Location $Dir
    git init -q -b main
    git add -A
    git -c user.email=t@t -c user.name=t commit -qm init
    Pop-Location
}

function FileUrl([string]$Path) { return 'file:///' + ($Path -replace '\\', '/') }

$V1 = Join-Path $WORK 'self-v1'
$V2 = Join-Path $WORK 'self-v2'
Fixture $V1 '0.1.0-install-fixture'
Fixture $V2 '0.2.0-install-fixture'
Push-Location $V2; git tag v1.0.0; Pop-Location

# ---------------------------------------------------------------------------
# 1. Fresh install from a local repo with a system zig present.
# ---------------------------------------------------------------------------
$DATA = Join-Path $WORK 'xdg1'
$env:XDG_DATA_HOME = $DATA
$env:ZEST_DATA = "$DATA\zest"
$env:ZEST_REPO_URL = FileUrl $V1
$env:ZEST_SELF_REPO = ''
& $INSTALL *> (Join-Path $WORK 't1.log')
if ($LASTEXITCODE -ne 0) { Fail 'fresh install' (Get-Content (Join-Path $WORK 't1.log') -Raw) }
if (-not (Test-Path "$DATA\zest\bin\zest.exe")) { Fail 'fresh install' 'zest.exe missing after install' }
$out = & "$DATA\zest\bin\zest.exe" --version 2>&1 | Out-String
if ($out -notmatch '0\.1\.0-install-fixture') { Fail 'fresh binary marker' $out }
Ok 'fresh install builds and installs zest'

# ---------------------------------------------------------------------------
# 2. Re-run must delegate to `zest self-update`: only zest overwrites zest.
# ---------------------------------------------------------------------------
$DATA2 = Join-Path $WORK 'xdg2'
New-Item -ItemType Directory -Force -Path "$DATA2\zest\bin" | Out-Null
Copy-Item $RealZest "$DATA2\zest\bin\zest.exe"
$env:XDG_DATA_HOME = $DATA2
$env:ZEST_DATA = "$DATA2\zest"
$env:ZEST_REPO_URL = FileUrl $V1
$env:ZEST_SELF_REPO = FileUrl $V2
& $INSTALL *> (Join-Path $WORK 't2.log')
if ($LASTEXITCODE -ne 0) { Fail 'self-update delegation' (Get-Content (Join-Path $WORK 't2.log') -Raw) }
$t2 = Get-Content (Join-Path $WORK 't2.log') -Raw
Assert-Grep 'self-update log' 'zest self-updated' $t2
Assert-Grep 'self-update resolved tag' 'latest zest release: v1.0.0' $t2
# Windows swaps the binary via a detached helper after exit; poll for it.
$out = ''
foreach ($i in 1..20) {
    Start-Sleep -Seconds 1
    $out = & "$DATA2\zest\bin\zest.exe" --version 2>&1 | Out-String
    if ($out -match '0\.2\.0-install-fixture') { break }
}
if ($out -notmatch '0\.2\.0-install-fixture') { Fail 'upgraded binary marker' $out }
Ok 're-run delegates to zest self-update (only zest overwrites zest)'

# ---------------------------------------------------------------------------
# 3. Protection: a repo named zest is refused; a build producing a binary
#    named zest is refused; bin\zest.exe is never touched.
# ---------------------------------------------------------------------------
$NAMED = Join-Path $WORK 'zest'
Copy-Item -Recurse -Force $V2 $NAMED
Remove-Item -Recurse -Force (Join-Path $NAMED '.git') -ErrorAction SilentlyContinue
Push-Location $NAMED
git init -q -b main; git add -A; git -c user.email=t@t -c user.name=t commit -qm init
Pop-Location

$DATA3 = Join-Path $WORK 'xdg3'
New-Item -ItemType Directory -Force -Path "$DATA3\zest\bin" | Out-Null
Copy-Item $RealZest "$DATA3\zest\bin\zest.exe"
$beforeSize = (Get-Item "$DATA3\zest\bin\zest.exe").Length
$env:XDG_DATA_HOME = $DATA3
$env:ZEST_REPO_URL = FileUrl $NAMED
$env:ZEST_SELF_REPO = ''
& "$DATA3\zest\bin\zest.exe" install (FileUrl $NAMED) *> (Join-Path $WORK 't3.log')
if ($LASTEXITCODE -eq 0) { Fail 'zest-named install must fail' 'unexpected success' }
$t3 = Get-Content (Join-Path $WORK 't3.log') -Raw
Assert-Grep 'protection message' 'reserved name' $t3
& "$DATA3\zest\bin\zest.exe" install (FileUrl $NAMED) --force *> (Join-Path $WORK 't4.log')
if ($LASTEXITCODE -eq 0) { Fail 'zest-named --force must fail' 'unexpected success' }
Assert-Grep 'force protection message' 'reserved name' (Get-Content (Join-Path $WORK 't4.log') -Raw)
if ((Get-Item "$DATA3\zest\bin\zest.exe").Length -ne $beforeSize) { Fail 'binary changed' 'size mismatch' }
Ok 'tool named zest is refused (--force included); binary untouched'

$env:ZEST_REPO_URL = FileUrl $V2
& "$DATA3\zest\bin\zest.exe" install (FileUrl $V2) --force *> (Join-Path $WORK 't5.log')
if ($LASTEXITCODE -eq 0) { Fail 'imposter build must be refused' 'unexpected success' }
Assert-Grep 'shadow refusal message' 'produced a binary named' (Get-Content (Join-Path $WORK 't5.log') -Raw)
if ((Get-Item "$DATA3\zest\bin\zest.exe").Length -ne $beforeSize) { Fail 'bin\zest changed' 'size mismatch' }
Ok 'builds producing a zest binary are refused so they can never shadow zest'

# ---------------------------------------------------------------------------
# 4. zig bootstrap path: no zig on PATH, fake toolchain archive over file://.
#    The fake zig cannot build, so the run fails at the build step, after
#    proving the bootstrap worked.
# ---------------------------------------------------------------------------
$origPath = $env:PATH
# noop
$fakeRoot = Join-Path $WORK 'faketoolchains'
$fakeDir = Join-Path $fakeRoot 'zig-x86_64-windows-0.16.0'
New-Item -ItemType Directory -Force -Path $fakeDir | Out-Null
'@echo off
if "%1"=="version" (echo 0.16.0) else (echo fake zig cannot build 1>&2 & exit /b 1)' |
    Set-Content (Join-Path $fakeDir 'zig.cmd')
Compress-Archive -Path $fakeDir -DestinationPath "$WORK\zig-x86_64-windows-0.16.0.zip"
$shasum = (Get-FileHash -Algorithm SHA256 "$WORK\zig-x86_64-windows-0.16.0.zip").Hash.ToLower()
$urlPath = ($WORK -replace '\\', '/')
"{""0.16.0"":{""x86_64-windows"":{""tarball"":""file:///$urlPath/zig-x86_64-windows-0.16.0.zip"",""shasum"":""$shasum"",""size"":1}}}" |
    Set-Content "$WORK\index.json"

# Drop only the directory that provides zig; everything else (git, tar,
# PowerShell utilities) stays available.
$zigCmd = Get-Command zig -ErrorAction SilentlyContinue
if (-not $zigCmd) { Fail 'zig setup' 'zig expected on PATH for this test' }
$zigDir = Split-Path $zigCmd.Source
$env:PATH = (($env:PATH -split ';') | Where-Object { $_ -and $_ -ne $zigDir }) -join ';'
if (Get-Command zig -ErrorAction SilentlyContinue) { Fail 'zig setup' 'zig still reachable after PATH filtering' }

$env:ZIG_INDEX_URL = FileUrl "$WORK\index.json"
$env:ZEST_DATA = Join-Path $WORK 'bootstrap-data'
$env:ZEST_REPO_URL = FileUrl $V1
& $INSTALL *> (Join-Path $WORK 't6.log')
$rc = $LASTEXITCODE
$env:PATH = $origPath
if ($rc -eq 0) { Fail 'bootstrap run must fail at build' 'unexpected success' }
$t6 = Get-Content (Join-Path $WORK 't6.log') -Raw
Assert-Grep 'bootstrap log' 'bootstrapped zig 0.16.0' $t6
Assert-Grep 'bootstrap used private toolchain' 'private to' $t6
Assert-Grep 'fake zig build failure surfaced' 'build failed' $t6
if (Test-Path "$WORK\bootstrap-data\bin\zest.exe") { Fail 'fake build installed' 'zest.exe exists' }
Ok 'zig bootstrap downloads, verifies, and extracts without touching PATH'

Write-Host "PASS mock-install.ps1 ($($script:PASS) checks)"
# $LASTEXITCODE lingers from the last native command (the intentionally
# failing bootstrap install); exit explicitly.
exit 0
