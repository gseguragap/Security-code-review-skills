<#
    merge-cost.ps1 - splice a measured cost.json into a findings.json as its "cost" block.

        merge-cost.ps1 -Findings <findings.json> -Cost <cost.json>

    Windows-native twin of merge-cost.py / merge-cost.sh. Same placeholder contract, same
    output: the line

        "cost": {},

    is replaced by the cost object, re-indented to sit where the placeholder sat.

    Exists so cost collection can run AFTER the findings document is written - authoring that
    document is the largest single output of an audit phase, and collecting cost first left it
    outside the measured window. The merge itself is deterministic text work and spends no
    model tokens.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Findings,
    [Parameter(Mandatory = $true)] [string] $Cost
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Findings)) { Write-Host "merge-cost: no findings document at $Findings"; exit 66 }
if (-not (Test-Path $Cost)) {
    Write-Host "merge-cost: no cost file at $Cost; leaving findings unchanged"
    exit 0
}

$costLines = @(Get-Content $Cost)
while ($costLines.Count -gt 0 -and $costLines[-1].Trim() -eq '') {
    $costLines = $costLines[0..($costLines.Count - 2)]
}

$placeholder = [regex] '^(\s*)"cost"\s*:\s*\{\s*\}\s*(,?)\s*$'
$out = New-Object System.Collections.Generic.List[string]
$spliced = $false

foreach ($line in Get-Content $Findings) {
    $m = $placeholder.Match($line)
    if (-not $spliced -and $m.Success) {
        $indent = $m.Groups[1].Value
        $comma  = $m.Groups[2].Value
        for ($i = 0; $i -lt $costLines.Count; $i++) {
            if ($i -eq 0) {
                $out.Add($indent + '"cost": ' + $costLines[$i])
            } elseif ($i -eq $costLines.Count - 1) {
                $out.Add($indent + $costLines[$i] + $comma)
            } else {
                $out.Add($indent + $costLines[$i])
            }
        }
        $spliced = $true
    } else {
        $out.Add($line)
    }
}

if (-not $spliced) {
    # A findings document with no placeholder is a contract violation, not something to paper
    # over: a report that silently carries no cost block is the failure this change prevents.
    # Write-Host, not Write-Error: under $ErrorActionPreference = 'Stop' an error record
    # aborts the script with exit code 1 and the documented 65 never reaches the caller.
    Write-Host 'merge-cost: findings document has no placeholder line for the cost block; leaving it unchanged'
    exit 65
}

# LF endings, matching the Python and awk twins byte for byte.
[System.IO.File]::WriteAllText(
    (Resolve-Path $Findings).Path,
    ($out -join "`n") + "`n",
    (New-Object System.Text.UTF8Encoding $false))

Write-Host "merge-cost: cost block spliced into $(Split-Path $Findings -Leaf)"
