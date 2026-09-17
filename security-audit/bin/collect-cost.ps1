<#
    collect-cost.ps1 - measure the token and dollar cost of a security-audit run.

    Windows-native twin of collect-cost.sh. Same arguments, same cost.json output.
    Exists so the skill needs NOTHING installed on Windows: PowerShell 5.1 ships with
    every Windows 10/11 machine, so cost accounting works even where Git Bash (and
    therefore awk) is absent.

        collect-cost.ps1 -Mark   -Out <dir> [-Transcript <file>]
        collect-cost.ps1 -Report -Out <dir> [-Transcript <file>] [-Pricing <pricing.json>]

    Dependencies: none beyond Windows PowerShell 5.1.

    Accuracy notes (identical to the awk implementation):
      * A single assistant message is written to the transcript several times
        (streaming partials plus a final record). Summing every line overstates cost
        by 2-3x, so records are keyed by message id and the MAXIMUM value seen per
        field is kept.
      * 5-minute and 1-hour cache writes bill at different multiples of the input
        rate, so they are tracked and priced separately.
      * Anything that cannot be determined is reported as such, rather than guessed.
#>

[CmdletBinding()]
param(
    [switch] $Mark,
    [switch] $Report,
    [Parameter(Mandatory = $true)] [string] $Out,
    [string] $Transcript,
    [string] $Pricing
)

$ErrorActionPreference = 'Stop'

if (-not $Mark -and -not $Report) { Write-Error 'Need -Mark or -Report'; exit 64 }
if ($Mark -and $Report)           { Write-Error 'Pass only one of -Mark / -Report'; exit 64 }

if (-not $Pricing) {
    $Pricing = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\pricing.json'
}
if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Force -Path $Out | Out-Null }
$markFile = Join-Path $Out 'cost-watermark'
$costFile = Join-Path $Out 'cost.json'

function Write-Utf8NoBom {
    # PowerShell 5.1's Set-Content -Encoding utf8 writes a BOM, and a BOM makes cost.json
    # unparseable by strict JSON parsers. LF endings keep this byte-identical to the twins.
    param([string] $Path, [string] $Text)
    $full = [System.IO.Path]::GetFullPath($Path)
    [System.IO.File]::WriteAllText($full, ($Text -replace "`r`n", "`n"),
        (New-Object System.Text.UTF8Encoding $false))
}

function Get-TranscriptPath {
    param([string] $Explicit)
    if ($Explicit -and (Test-Path $Explicit)) { return (Resolve-Path $Explicit).Path }
    if ($env:CLAUDE_TRANSCRIPT -and (Test-Path $env:CLAUDE_TRANSCRIPT)) { return $env:CLAUDE_TRANSCRIPT }

    $base = if ($env:CLAUDE_CONFIG_DIR) { Join-Path $env:CLAUDE_CONFIG_DIR 'projects' }
            else { Join-Path $HOME '.claude\projects' }
    if (-not (Test-Path $base)) { return $null }

    # The live session's transcript is the most recently written top-level .jsonl,
    # because it is being appended to right now.
    $c = Get-ChildItem -Path $base -Filter *.jsonl -Depth 1 -File -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($c) { return $c.FullName }
    return $null
}

# ----------------------------------------------------------------------- mark
if ($Mark) {
    $t = Get-TranscriptPath -Explicit $Transcript
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    if (-not $t) {
        Write-Utf8NoBom $markFile "unavailable`t0`t$stamp`n"
        Write-Host 'collect-cost: no transcript found; cost will be reported as unavailable.'
        exit 0
    }
    $lines = 0
    foreach ($null in [System.IO.File]::ReadLines($t)) { $lines++ }
    Write-Utf8NoBom $markFile "$t`t$lines`t$stamp`n"
    Write-Host "collect-cost: watermark set at line $lines of $t"
    exit 0
}

# --------------------------------------------------------------------- report
# A measured figure is only ever produced from a watermark that still resolves. Every other
# path reports "unavailable": rescanning the whole transcript would bill the entire session
# to the audit and label it measured - silent, and confidently wrong.
$started = 'unknown'; $skip = 0; $t = $null

function Write-Unmeasured {
    param([string] $Why)
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $esc = { param($s) $s -replace '\\', '\\' -replace '"', '\"' }
    @"
{
  "source": "unavailable",
  "reason": "$(& $esc $Why)",
  "startedAt": "$(& $esc $script:started)",
  "finishedAt": "$stamp",
  "byModel": [],
  "totals": { "totalTokens": 0, "totalCostUSD": null },
  "note": "Cost was not measured. Supply an estimate and set source to 'estimate', or state that cost is unavailable. Do not present an unmeasured figure as measured."
}
"@ | ForEach-Object { Write-Utf8NoBom $script:costFile $_ }
    Write-Host "collect-cost: $Why - wrote cost.json with source=unavailable"
    exit 0
}

if (-not (Test-Path $markFile)) {
    Write-Unmeasured 'No cost-watermark in the output directory: the run never marked a start point, so there is no window to measure.'
}
$parts = ((Get-Content $markFile -First 1) -replace "`r", "") -split "`t"
if ($parts.Count -lt 3) { Write-Unmeasured 'The cost-watermark is malformed and cannot be read.' }
$started = $parts[2]
if ($parts[0] -eq 'unavailable') { Write-Unmeasured 'No session transcript was found when the watermark was set.' }
$skip = [int]$parts[1]

if (Test-Path $parts[0]) {
    $t = $parts[0]
} elseif ($Transcript -and (Test-Path $Transcript)) {
    # An explicit -Transcript may relocate a file that has moved. The recorded offset still
    # applies, so this re-points at the same transcript - it never selects a different session.
    $t = $Transcript
} else {
    Write-Unmeasured "The transcript recorded in the watermark is no longer readable ($($parts[0]))."
}

$totalLines = 0
foreach ($null in [System.IO.File]::ReadLines($t)) { $totalLines++ }
if ($skip -gt $totalLines) {
    Write-Unmeasured "The watermark starts at line $skip but the transcript now holds only $totalLines lines: it was rotated or truncated mid-run."
}

$finished = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')


# Regex extraction rather than ConvertFrom-Json per line: transcript lines are large
# and numerous, and we need only six numbers from each.
$reId   = [regex] '"id":"(msg_[^"]*)"'
$reMdl  = [regex] '"model":"([^"]*)"'
$reIn   = [regex] '"input_tokens":(\d+)'
$reOut  = [regex] '"output_tokens":(\d+)'
$reRead = [regex] '"cache_read_input_tokens":(\d+)'
$reW5   = [regex] '"ephemeral_5m_input_tokens":(\d+)'
$reW1   = [regex] '"ephemeral_1h_input_tokens":(\d+)'
$reCC   = [regex] '"cache_creation_input_tokens":(\d+)'

$msgs = @{}
$n = 0

function Set-Max {
    param($Bag, [string]$Key, [long]$Value)
    if ($Value -gt $Bag[$Key]) { $Bag[$Key] = $Value }
}

foreach ($line in [System.IO.File]::ReadLines($t)) {
    $n++
    if ($n -le $skip) { continue }
    if ($line.IndexOf('"type":"assistant"') -lt 0) { continue }

    $mId = $reId.Match($line)
    if (-not $mId.Success) { continue }
    $id = $mId.Groups[1].Value

    if (-not $msgs.ContainsKey($id)) {
        $msgs[$id] = @{ model = 'unknown'; input = 0L; w5 = 0L; w1 = 0L; read = 0L; output = 0L; cc = 0L }
    }
    $b = $msgs[$id]

    $m = $reMdl.Match($line);  if ($m.Success) { $b.model = $m.Groups[1].Value }
    $m = $reIn.Match($line);   if ($m.Success) { Set-Max $b 'input'  ([long]$m.Groups[1].Value) }
    $m = $reOut.Match($line);  if ($m.Success) { Set-Max $b 'output' ([long]$m.Groups[1].Value) }
    $m = $reRead.Match($line); if ($m.Success) { Set-Max $b 'read'   ([long]$m.Groups[1].Value) }
    $m = $reW5.Match($line);   if ($m.Success) { Set-Max $b 'w5'     ([long]$m.Groups[1].Value) }
    $m = $reW1.Match($line);   if ($m.Success) { Set-Max $b 'w1'     ([long]$m.Groups[1].Value) }
    $m = $reCC.Match($line);   if ($m.Success) { Set-Max $b 'cc'     ([long]$m.Groups[1].Value) }
}

# Subagent transcripts written after the mark.
$sessionDir = [System.IO.Path]::ChangeExtension($t, $null).TrimEnd('.')
$subDir = Join-Path $sessionDir 'subagents'
if (Test-Path $subDir) {
    $markStamp = if (Test-Path $markFile) { (Get-Item $markFile).LastWriteTime } else { [datetime]::MinValue }
    foreach ($sf in Get-ChildItem $subDir -Filter *.jsonl -File -ErrorAction SilentlyContinue) {
        if ($sf.LastWriteTime -lt $markStamp) { continue }
        foreach ($line in [System.IO.File]::ReadLines($sf.FullName)) {
            if ($line.IndexOf('"type":"assistant"') -lt 0) { continue }
            $mId = $reId.Match($line); if (-not $mId.Success) { continue }
            $id = $mId.Groups[1].Value
            if (-not $msgs.ContainsKey($id)) {
                $msgs[$id] = @{ model = 'unknown'; input = 0L; w5 = 0L; w1 = 0L; read = 0L; output = 0L; cc = 0L }
            }
            $b = $msgs[$id]
            $m = $reMdl.Match($line);  if ($m.Success) { $b.model = $m.Groups[1].Value }
            $m = $reIn.Match($line);   if ($m.Success) { Set-Max $b 'input'  ([long]$m.Groups[1].Value) }
            $m = $reOut.Match($line);  if ($m.Success) { Set-Max $b 'output' ([long]$m.Groups[1].Value) }
            $m = $reRead.Match($line); if ($m.Success) { Set-Max $b 'read'   ([long]$m.Groups[1].Value) }
            $m = $reW5.Match($line);   if ($m.Success) { Set-Max $b 'w5'     ([long]$m.Groups[1].Value) }
            $m = $reW1.Match($line);   if ($m.Success) { Set-Max $b 'w1'     ([long]$m.Groups[1].Value) }
            $m = $reCC.Match($line);   if ($m.Success) { Set-Max $b 'cc'     ([long]$m.Groups[1].Value) }
        }
    }
}

if ($msgs.Count -eq 0) {
    Write-Unmeasured "No assistant turns were found after line $skip of the transcript. The watermark does not line up with this session, so no cost can be attributed to it."
}

# ------------------------------------------------------------------ aggregate
$agg = @{}
foreach ($id in $msgs.Keys) {
    $b = $msgs[$id]
    $w5 = $b.w5; $w1 = $b.w1
    # No per-TTL breakdown (older transcript): attribute to the 5-minute rate, the
    # cheaper of the two. This understates rather than overstates - the honest way to err.
    if ($w5 -eq 0 -and $w1 -eq 0 -and $b.cc -gt 0) { $w5 = $b.cc }

    $k = $b.model
    if (-not $agg.ContainsKey($k)) {
        $agg[$k] = @{ messages = 0; input = 0L; w5 = 0L; w1 = 0L; read = 0L; output = 0L }
    }
    $a = $agg[$k]
    $a.messages++; $a.input += $b.input; $a.w5 += $w5; $a.w1 += $w1
    $a.read += $b.read; $a.output += $b.output
}

# -------------------------------------------------------------------- pricing
$rates = $null
$pricingVersion = 'unknown'
if (Test-Path $Pricing) {
    $pj = Get-Content $Pricing -Raw | ConvertFrom-Json
    $rates = $pj.models
    if ($pj.pricingVersion) { $pricingVersion = $pj.pricingVersion }
}

function Esc-Json { param([string]$s) if ($null -eq $s) { return '' } $s.Replace('\', '\\').Replace('"', '\"') }

$rows = New-Object System.Collections.ArrayList
$grandTokens = 0L; $grandCost = 0.0; $unpriced = 0

foreach ($model in ($agg.Keys | Sort-Object)) {
    $a = $agg[$model]
    $tok = $a.input + $a.w5 + $a.w1 + $a.read + $a.output
    $grandTokens += $tok

    $r = $null
    if ($rates -and ($rates.PSObject.Properties.Name -contains $model)) { $r = $rates.$model }

    if ($r) {
        $cIn = $a.input  * [double]$r.input        / 1000000
        $c5  = $a.w5     * [double]$r.cacheWrite5m / 1000000
        $c1  = $a.w1     * [double]$r.cacheWrite1h / 1000000
        $cRd = $a.read   * [double]$r.cacheRead    / 1000000
        $cOu = $a.output * [double]$r.output       / 1000000
        $tot = $cIn + $c5 + $c1 + $cRd + $cOu
        $grandCost += $tot
        $null = $rows.Add(@"
    {
      "model": "$(Esc-Json $model)",
      "priced": true,
      "messages": $($a.messages),
      "tokens": { "input": $($a.input), "cacheWrite5m": $($a.w5), "cacheWrite1h": $($a.w1), "cacheRead": $($a.read), "output": $($a.output), "total": $tok },
      "rates": { "input": $('{0:F2}' -f [double]$r.input), "cacheWrite5m": $('{0:F2}' -f [double]$r.cacheWrite5m), "cacheWrite1h": $('{0:F2}' -f [double]$r.cacheWrite1h), "cacheRead": $('{0:F2}' -f [double]$r.cacheRead), "output": $('{0:F2}' -f [double]$r.output) },
      "costUSD": { "input": $('{0:F6}' -f $cIn), "cacheWrite5m": $('{0:F6}' -f $c5), "cacheWrite1h": $('{0:F6}' -f $c1), "cacheRead": $('{0:F6}' -f $cRd), "output": $('{0:F6}' -f $cOu), "total": $('{0:F6}' -f $tot) }
    }
"@)
    }
    else {
        $unpriced++
        $null = $rows.Add(@"
    {
      "model": "$(Esc-Json $model)",
      "priced": false,
      "messages": $($a.messages),
      "tokens": { "input": $($a.input), "cacheWrite5m": $($a.w5), "cacheWrite1h": $($a.w1), "cacheRead": $($a.read), "output": $($a.output), "total": $tok },
      "rates": null,
      "costUSD": null
    }
"@)
    }
}

$body = @"
{
  "source": "transcript",
  "startedAt": "$(Esc-Json $started)",
  "finishedAt": "$finished",
  "transcript": "$(Esc-Json $t)",
  "fromLine": $skip,
  "byModel": [
$($rows -join ",`r`n")
  ],
  "totals": { "totalTokens": $grandTokens, "totalCostUSD": $('{0:F4}' -f $grandCost) },
  "unpricedModels": $unpriced,
  "pricingVersion": "$(Esc-Json $pricingVersion)",
  "note": "Measured from the session transcript. Assistant messages are deduplicated by message id. Dollar figures use the list rates in assets/pricing.json and exclude any enterprise discount, Batch API discount or partner-platform pricing."
}
"@

Write-Utf8NoBom $costFile $body
Write-Host "collect-cost: wrote $costFile"
