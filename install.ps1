# zest bootstrap installer (Windows PowerShell) for https://github.com/JustinWoodring/zest
#
#   # PowerShell:
#   irm https://justinwoodring.github.io/zest/install.ps1 | iex
#
# Mirrors install.sh:
#   0. If zest is already installed, hand over to `zest self-update`, which is the only
#      zest itself may overwrite the zest binary; this script never does.
#   1. Use a system zig >= $env:ZIG_VERSION, or bootstrap a private toolchain
#      under $env:ZEST_DATA\toolchains (SHA-256 verified, no admin needed).
#   2. Clone zest and build it in ReleaseSafe with the native zig build
#      pipeline.
#   3. Atomically install the binary at $env:ZEST_DATA\bin\zest.exe.
#
# Environment overrides: ZEST_REPO_URL, ZEST_REF, ZIG_VERSION, ZIG_INDEX_URL,
# ZEST_DATA.

$ErrorActionPreference = 'Stop'

# Non-interactive answers for automation: -Yes / -NoPath. Without either, the
# installer prompts before editing your PowerShell profile.
$PathDecision = 'ask'
foreach ($a in $args) {
    switch -Regex ($a) {
        '^(-y|--yes|Yes)$'                 { $PathDecision = 'yes' }
        '^(-n|--no|--no-path|No|NoPath)$'  { $PathDecision = 'no' }
        '^(-h|--help|Help|\?)$' {
            Write-Host 'usage: install.ps1 [-Yes] [-NoPath]'
            Write-Host '  -Yes      add the zest bin dir to PATH without prompting'
            Write-Host '  -NoPath   do not touch PATH'
            Write-Host 'With neither, the installer asks before editing your profile.'
            exit 0
        }
    }
}

if (-not $env:ZEST_REPO_URL)  { $env:ZEST_REPO_URL  = 'https://github.com/JustinWoodring/zest' }
if (-not $env:ZEST_REF)       { $env:ZEST_REF       = '' }
if (-not $env:ZIG_VERSION)    { $env:ZIG_VERSION    = '0.16.0' }
if (-not $env:ZIG_INDEX_URL)  { $env:ZIG_INDEX_URL  = 'https://ziglang.org/download/index.json' }
if (-not $env:ZEST_DATA) {
    $dataHome = if ($env:XDG_DATA_HOME -and $env:XDG_DATA_HOME -match '^[A-Za-z]:[\\/]') {
        $env:XDG_DATA_HOME
    } elseif ($env:LOCALAPPDATA) {
        $env:LOCALAPPDATA
    } else {
        Join-Path $env:USERPROFILE 'AppData\Local'
    }
    $env:ZEST_DATA = Join-Path $dataHome 'zest'
}
$ZestBin = Join-Path $env:ZEST_DATA 'bin\zest.exe'

function Log([string]$Msg) { Write-Host "zest-install: $Msg" }
function Fetch([string]$Uri, [string]$Out) {
    if ($Uri -match '^file://') {
        $src = ($Uri -replace '^file:///', '') -replace '/', '\\'
        Copy-Item $src $Out -Force
    } else {
        Invoke-WebRequest -Uri $Uri -OutFile $Out
    }
}
function FetchJson([string]$Uri) {
    if ($Uri -match '^file://') {
        $src = ($Uri -replace '^file:///', '') -replace '/', '\\'
        Get-Content $src -Raw | ConvertFrom-Json
    } else {
        Invoke-RestMethod -Uri $Uri
    }
}
function Die([string]$Msg) { Write-Host "zest-install: error: $Msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# 0. Existing zest wins: only zest may overwrite zest.
# ---------------------------------------------------------------------------
if (Test-Path $ZestBin -PathType Leaf) {
    Log "found existing zest at $ZestBin; delegating upgrade to zest itself"
    & $ZestBin self-update
    exit $LASTEXITCODE
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die 'missing dependency: git' }

# ---------------------------------------------------------------------------
# 1. zig: system toolchain if new enough, else a private bootstrapped copy.
# ---------------------------------------------------------------------------
$Zig = $null
function Test-ZigOk {
    try { $v = (& zig version 2>$null).Trim() } catch { return $false }
    if (-not $v) { return $false }
    try {
        $have = [version]($v -replace '-.*$', '')
        $want = [version]$env:ZIG_VERSION
        return $have -ge $want
    } catch { return $false }
}

if (Test-ZigOk) {
    $Zig = 'zig'
    Log "using system zig $(& zig version)"
} else {
    $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'x86_64' }
        'ARM64' { 'aarch64' }
        'X86'   { 'x86' }
        default { Die "unsupported architecture: $env:PROCESSOR_ARCHITECTURE (install zig $env:ZIG_VERSION manually)" }
    }
    $key = "$arch-windows"
    $toolchains = Join-Path $env:ZEST_DATA 'toolchains'
    New-Item -ItemType Directory -Force -Path $toolchains | Out-Null
    Log "no zig >= $env:ZIG_VERSION in PATH; bootstrapping zig $env:ZIG_VERSION ($key)"

    $index = FetchJson $env:ZIG_INDEX_URL
    $entry = $index.$env:ZIG_VERSION.$key
    if (-not $entry -or -not $entry.tarball) {
        Die "zig $env:ZIG_VERSION ($key) not found in $env:ZIG_INDEX_URL; install zig manually and re-run"
    }
    $tarball = $entry.tarball
    $shasum  = $entry.shasum

    $archive = Join-Path $toolchains (Split-Path $tarball -Leaf)
    Fetch $tarball $archive

    $actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLower()
    if ($actual -ne $shasum) { Die "zig archive checksum mismatch (want $shasum, got $actual)" }

    $dest = Join-Path $toolchains "zig-$key-$env:ZIG_VERSION"
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Expand-Archive -Path $archive -DestinationPath $toolchains -Force
    Remove-Item -Force $archive

    $Zig = Join-Path $dest 'zig.exe'
    if (-not (Test-Path $Zig -PathType Leaf)) {
        $Zig = (Get-ChildItem -Path $toolchains -Recurse -Include 'zig.exe', 'zig.cmd' |
            Select-Object -First 1).FullName
    }
    if (-not ($Zig -and (Test-Path $Zig -PathType Leaf))) { Die 'bootstrapped zig not found after extraction' }
    Log "bootstrapped zig $(& $Zig version) at $Zig (private to $($env:ZEST_DATA))"
}

# ---------------------------------------------------------------------------
# 2. Clone + build zest (ReleaseSafe, native zig build pipeline).
# ---------------------------------------------------------------------------
$Src = Join-Path $env:ZEST_DATA 'self\src'
if (Test-Path (Join-Path $Src '.git')) {
    Log "updating zest source at $Src"
    if ($env:ZEST_REF) {
        & git -C $Src fetch --quiet --depth 1 --force --tags origin $env:ZEST_REF 2>$null
        if ($LASTEXITCODE -ne 0) { Die "could not fetch $($env:ZEST_REF) from $($env:ZEST_REPO_URL)" }
    } else {
        & git -C $Src fetch --quiet --depth 1 --force origin HEAD 2>$null
        if ($LASTEXITCODE -ne 0) { Die "could not fetch zest source from $($env:ZEST_REPO_URL)" }
    }
    & git -C $Src checkout --quiet --force --detach FETCH_HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { Die 'could not check out the zest source' }
    & git -C $Src reset --quiet --hard FETCH_HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { Die 'could not reset the zest source' }
} else {
    if (Test-Path $Src) { Remove-Item -Recurse -Force $Src }
    Log "cloning $($env:ZEST_REPO_URL) -> $Src"
    if ($env:ZEST_REF) {
        & git clone --quiet --depth 1 -b $env:ZEST_REF $env:ZEST_REPO_URL $Src
    } else {
        & git clone --quiet --depth 1 $env:ZEST_REPO_URL $Src
    }
    if ($LASTEXITCODE -ne 0) { Die "could not clone $($env:ZEST_REPO_URL)" }
}

Log 'building zest (ReleaseSafe) with zig build'
Push-Location $Src
& $Zig build -p dist '-Doptimize=ReleaseSafe' --summary none
$buildRc = $LASTEXITCODE
Pop-Location
if ($buildRc -ne 0) { Die 'zest build failed' }

$NewBin = Join-Path $Src 'dist\bin\zest.exe'
if (-not (Test-Path $NewBin -PathType Leaf)) { Die 'build did not produce dist\bin\zest.exe' }

# ---------------------------------------------------------------------------
# 3. Atomic install into $ZEST_DATA\bin. We only get here when $ZestBin did
#    not exist (step 0), so this is a fresh install, never an overwrite.
# ---------------------------------------------------------------------------
$BinDir = Join-Path $env:ZEST_DATA 'bin'
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
$Tmp = Join-Path $BinDir '.zest.tmp'
Copy-Item $NewBin $Tmp -Force
Move-Item -Force $Tmp $ZestBin

Log "installed $ZestBin ($(& $ZestBin --version 2>$null | Select-Object -First 1))"

$binPathEntry = Join-Path $env:ZEST_DATA 'bin'
$onPath = ($env:PATH -split ';') -contains $binPathEntry
if ($onPath) {
    Log "$binPathEntry is already on your PATH; 'zest' and installed tools are callable by name"
} else {
    $profile = $PROFILE.CurrentUserAllHosts
    function Persist-Path {
        $line = "`$env:PATH = `"$binPathEntry;`$env:PATH`""
        if ((Test-Path $profile) -and ((Get-Content $profile -Raw) -match [regex]::Escape($binPathEntry))) {
            Log "$profile already references $binPathEntry"
        } else {
            New-Item -ItemType Directory -Force -Path (Split-Path $profile) | Out-Null
            Add-Content -Path $profile -Value "`n# zest toolchain`n$line"
            Log "added $binPathEntry to PATH via $profile"
        }
        Log 'open a new PowerShell window (or dot-source the profile) to use it now'
    }
    if ($PathDecision -eq 'yes') {
        Persist-Path
    } elseif ($PathDecision -eq 'no') {
        Log 'skipping PATH; add the bin dir yourself or run tools with zest run'
    } else {
        $answer = Read-Host "Add $binPathEntry to your PATH so 'zest' and installed tools run by name? [Y/n]"
        if ($answer -match '^(n|no)$') {
            Log 'skipping PATH; run tools with zest run'
        } else {
            Persist-Path
        }
    }
}
Log 'done; upgrade any time with: zest self-update (or re-run this script)'
