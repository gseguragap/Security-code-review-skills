# phase-gate.ps1 - refuse to start a comparison until both audits have finished, in order.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File phase-gate.ps1 -Legacy <findings.json> -Modernized <findings.json>
#
# PowerShell 5.1 twin of phase-gate.sh - same checks, same exit codes, same messages. See that
# file for the rule it enforces. Exit 0 = PASS, 3 = BLOCKED (reason on stderr), 64 = bad arguments.

param(
    [string]$Legacy,
    [string]$Modernized
)

$ErrorActionPreference = 'Stop'

if (-not $Legacy -or -not $Modernized) {
    [Console]::Error.WriteLine('phase-gate.ps1: need -Legacy <findings.json> and -Modernized <findings.json>')
    exit 64
}

function Stop-Gate {
    param([string]$Reason)
    [Console]::Error.WriteLine("phase-gate: BLOCKED - $Reason")
    [Console]::Error.WriteLine('phase-gate: the comparison must not start until the Legacy and then the Modernized audit have each written their report.')
    exit 3
}

# The folder the audit rendered its report into: the parent of the .security-audit directory
# that holds the findings document, or the findings document's own folder if there is none.
function Get-ReportDir {
    param([string]$Findings)
    $d = (Get-Item -LiteralPath $Findings).Directory
    $walk = $d
    while ($walk) {
        if ($walk.Name -eq '.security-audit') { return $walk.Parent.FullName }
        $walk = $walk.Parent
    }
    return $d.FullName
}

function Get-SideReport {
    param([string]$Label, [string]$Findings, [string]$ReportDir)
    $variant = (Get-Item -LiteralPath $Findings).Directory.Name
    if ($variant -eq 'legacy' -or $variant -eq 'modernized') { $pattern = "* - $Label - Security analysis report*.html" }
    else { $pattern = '*Security analysis report*.html' }
    Get-ChildItem -LiteralPath $ReportDir -File |
        Where-Object { $_.Name -like $pattern -and $_.Name -notlike '* - Comparison - *' } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

function Test-Side {
    param([string]$Label, [string]$Findings)
    if (-not (Test-Path -LiteralPath $Findings -PathType Leaf)) {
        Stop-Gate "$Label findings document not found: $Findings. The $Label audit has not run, or has not finished."
    }
    $item = Get-Item -LiteralPath $Findings
    if ($item.Length -eq 0) { Stop-Gate "$Label findings document is empty: $Findings." }
    $text = [IO.File]::ReadAllText($item.FullName)
    if ($text -notmatch '"meta"' -or $text -notmatch '"findings"') {
        Stop-Gate "$Findings is not a security-audit findings document."
    }
    if ($text -match '(?m)^[ \t]*"cost"[ \t]*:[ \t]*\{[ \t]*\}[ \t]*,?[ \t]*\r?$') {
        Stop-Gate "$Label audit has not finished: its cost block is still the placeholder, so its final steps (cost merge, report) have not run."
    }
    $rdir = Get-ReportDir $Findings
    $report = Get-SideReport $Label $Findings $rdir
    if (-not $report) { Stop-Gate "$Label report not found in $rdir. A phase is complete only once its HTML report is written." }
    if ($item.LastWriteTimeUtc -gt $report.LastWriteTimeUtc) {
        Stop-Gate "$Label report ($($report.Name)) is older than its findings document - it was not rendered from the finished audit."
    }
    return $report
}

$lReport = Test-Side 'Legacy' $Legacy
$mReport = Test-Side 'Modernized' $Modernized

# Order: in the orchestrated layout, nothing the Modernized phase wrote may predate the Legacy report.
if ((Get-ReportDir $Legacy) -eq (Get-ReportDir $Modernized)) {
    $mDir = (Get-Item -LiteralPath $Modernized).Directory.FullName
    $early = Get-ChildItem -LiteralPath $mDir -File |
        Where-Object { $_.LastWriteTimeUtc -le $lReport.LastWriteTimeUtc } |
        Select-Object -First 1
    if ($early) {
        Stop-Gate "the Modernized phase started before the Legacy report existed ($($early.Name) predates $($lReport.Name)). Re-run the Modernized audit after the Legacy report."
    }
}

Write-Output "phase-gate: PASS - Legacy report: $($lReport.Name); Modernized report: $($mReport.Name)"
exit 0
