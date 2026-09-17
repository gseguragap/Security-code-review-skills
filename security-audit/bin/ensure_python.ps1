<#
    ensure_python.ps1 - resolve a usable Python interpreter, without ever demanding an install.

        ensure_python.ps1 [-AllowDownload] [-Quiet] [-Min 3.9]

    Writes the absolute path of a working Python to stdout and exits 0.
    Exits 1 if none could be resolved - callers MUST fall back, never fail the audit.

    Resolution order (first hit wins):
      1. $env:SECURITY_AUDIT_PYTHON     explicit override
      2. PATH candidates, PROBED
      3. Well-known install locations   catches installs that are not on PATH
      4. Previously bootstrapped cache
      5. Bootstrap download             ONLY with -AllowDownload

    Why probing rather than Get-Command:
      %LOCALAPPDATA%\Microsoft\WindowsApps\python.exe is a 0-byte App Execution Alias that
      resolves on PATH, prints a Microsoft Store advert and exits non-zero. Anything that
      trusts Get-Command picks it and breaks. We run real code and check the exit status,
      which the stub cannot fake. Step 3 matters just as much: a correct PATH in the registry
      is invisible to an already-running process that started before Python was installed, so
      the interpreter is frequently present but unreachable via PATH.
#>

[CmdletBinding()]
param(
    [switch] $AllowDownload,
    [switch] $Quiet,
    [string] $Min = '3.9'
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$minParts = $Min -split '\.'
$minMaj = [int]$minParts[0]
$minMin = [int]$minParts[1]

function Say { param([string]$m) if (-not $Quiet) { Write-Host "ensure_python: $m" -ForegroundColor DarkGray } }

function Test-Py {
    param([string]$Exe)
    if (-not $Exe) { return $false }
    if (-not (Test-Path $Exe)) { return $false }
    # A 0-byte alias stub cannot execute this.
    & $Exe -c "import sys; sys.exit(0 if sys.version_info >= ($minMaj, $minMin) else 1)" 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ------------------------------------------------------------------ 1. override
if ($env:SECURITY_AUDIT_PYTHON) {
    if (Test-Py $env:SECURITY_AUDIT_PYTHON) { Write-Output $env:SECURITY_AUDIT_PYTHON; exit 0 }
    Say "SECURITY_AUDIT_PYTHON is set but not usable: $env:SECURITY_AUDIT_PYTHON"
}

# ------------------------------------------------------------------ 2. PATH
foreach ($c in @('python3', 'python', 'py')) {
    $g = Get-Command $c -ErrorAction SilentlyContinue
    if ($g -and (Test-Py $g.Source)) { Write-Output $g.Source; exit 0 }
}

# ------------------------------------------------------------------ 3. well-known
$globs = @(
    "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
    "$env:ProgramFiles\Python3*\python.exe",
    "${env:ProgramFiles(x86)}\Python3*\python.exe",
    "C:\Python3*\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Launcher\py.exe"
)
$cands = foreach ($g in $globs) { Get-ChildItem $g -ErrorAction SilentlyContinue | Select-Object -Expand FullName }
# Newest version directory first.
foreach ($c in ($cands | Sort-Object -Descending)) {
    if (Test-Py $c) { Write-Output $c; exit 0 }
}

# Also consult the registry PATH, which is often correct while the current process is stale.
$mach = (Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction SilentlyContinue).GetValue('Path','','DoNotExpandEnvironmentNames')
$usr  = (Get-Item 'HKCU:\Environment' -ErrorAction SilentlyContinue).GetValue('Path','','DoNotExpandEnvironmentNames')
foreach ($dir in ([Environment]::ExpandEnvironmentVariables("$mach;$usr") -split ';')) {
    if (-not $dir) { continue }
    foreach ($n in @('python.exe')) {
        $p = Join-Path $dir $n
        if ((Test-Path $p) -and (Test-Py $p)) { Write-Output $p; exit 0 }
    }
}

# ------------------------------------------------------------------ 4. cache
$manifest = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\python-bootstrap.json'
$ver = $null; $mf = $null
if (Test-Path $manifest) {
    $mf  = Get-Content $manifest -Raw | ConvertFrom-Json
    $ver = $mf.version
}
$cacheRoot = if ($env:CLAUDE_CONFIG_DIR) { Join-Path $env:CLAUDE_CONFIG_DIR 'cache\security-audit\python' }
             else { Join-Path $HOME '.claude\cache\security-audit\python' }
if ($ver) {
    foreach ($e in @("$cacheRoot\$ver\python\python.exe", "$cacheRoot\$ver\python\bin\python3")) {
        if (Test-Py $e) { Write-Output $e; exit 0 }
    }
}

# ------------------------------------------------------------------ 5. bootstrap
if (-not $AllowDownload) {
    Say 'no usable Python found. Not downloading (pass -AllowDownload to permit).'
    exit 1
}
if (-not $mf) { Say "manifest missing: $manifest"; exit 1 }

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x86_64' }
$key  = "windows-$arch"
$plat = $mf.platforms.$key
if (-not $plat) { Say "no pinned build for $key"; exit 1 }

$dest = Join-Path $cacheRoot $ver
$tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ("sa-py-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp  | Out-Null
New-Item -ItemType Directory -Force $dest | Out-Null
$archive = Join-Path $tmp $plat.file

Say "downloading CPython $ver for $key (~30 MB) into $dest"
try { Invoke-WebRequest -Uri ($mf.baseUrl + $plat.file) -OutFile $archive -UseBasicParsing -TimeoutSec 300 }
catch { Say "download failed: $($_.Exception.Message)"; Remove-Item $tmp -Recurse -Force; exit 1 }

# Verify BEFORE extracting. An unverified archive is never unpacked, let alone executed.
$actual = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $plat.sha256.ToLower()) {
    Say 'CHECKSUM MISMATCH - refusing to extract.'
    Say "  expected $($plat.sha256)"
    Say "  actual   $actual"
    Remove-Item $tmp -Recurse -Force
    exit 1
}

# tar.exe ships with Windows 10 1803+ and handles .tar.gz.
& tar.exe -xzf $archive -C $dest
if ($LASTEXITCODE -ne 0) { Say 'extract failed'; Remove-Item $tmp -Recurse -Force; exit 1 }
Remove-Item $tmp -Recurse -Force

foreach ($e in @("$dest\python\python.exe", "$dest\python\bin\python3")) {
    if (Test-Py $e) { Say "bootstrapped $e"; Write-Output $e; exit 0 }
}
Say 'bootstrap completed but no working interpreter was produced'
exit 1
