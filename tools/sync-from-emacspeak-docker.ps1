<#
.SYNOPSIS
Compare the shared installer files between a local emacspeak-docker clone
and this repository, and copy the differing ones with -Apply.

.DESCRIPTION
The installer scripts and their GitHub workflows live in two repositories:
emacspeak-docker, where the Docker image also uses them, and this one, for
people who want only the scripts. This tool lists, for each shared file,
whether the two copies are the same, differ, or are missing on one side.
With -Apply it copies the differing files from the emacspeak-docker clone
into this repository; with -Reverse it copies the other way. It never
deletes anything. It finds this repository from its own location, so it
can be run from anywhere.

.PARAMETER Source
The local clone of emacspeak-docker. Default: D:\emacspeak-docker.

.PARAMETER Apply
Copy the files that differ. Without it, only report.

.PARAMETER Reverse
Copy from this repository into the emacspeak-docker clone instead.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File tools\sync-from-emacspeak-docker.ps1

.EXAMPLE
powershell -ExecutionPolicy Bypass -File tools\sync-from-emacspeak-docker.ps1 -Apply
#>
[CmdletBinding()]
param(
    [string]$Source = 'D:\emacspeak-docker',
    [switch]$Apply,
    [switch]$Reverse
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $PSScriptRoot
$shared = @(
    'scripts\install-emacspeak-fedora.sh',
    'scripts\install-emacspeak-debian.sh',
    'scripts\install-emacspeak-arch.sh',
    'scripts\install-emacspeak-macos.sh',
    'scripts\install-emacspeak-windows.ps1',
    'scripts\install-emacspeak-voxin.sh',
    '.github\workflows\macos-installer.yml',
    '.github\workflows\windows-installer.yml'
)

if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    Write-Output "ERROR: the emacspeak-docker clone was not found at $Source. Pass -Source with its folder."
    exit 1
}
if ($Reverse) {
    $from = $here; $to = $Source
    Write-Output "Direction: from this repository ($here) into the emacspeak-docker clone ($Source)."
} else {
    $from = $Source; $to = $here
    Write-Output "Direction: from the emacspeak-docker clone ($Source) into this repository ($here)."
}
if (-not $Apply) { Write-Output 'Report only; add -Apply to copy the files that differ.' }

$changed = 0
foreach ($rel in $shared) {
    $a = Join-Path $from $rel
    $b = Join-Path $to $rel
    if (-not (Test-Path -LiteralPath $a -PathType Leaf)) {
        Write-Output "missing in source: $rel"
        continue
    }
    if (-not (Test-Path -LiteralPath $b -PathType Leaf)) {
        $state = 'missing here'
    } else {
        $ha = (Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash
        $hb = (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash
        if ($ha -eq $hb) { $state = 'same' } else { $state = 'differs' }
    }
    Write-Output "$state  $rel"
    if ($Apply -and $state -ne 'same') {
        $dir = Split-Path -Parent $b
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir | Out-Null
        }
        Copy-Item -LiteralPath $a -Destination $b -Force
        Write-Output "  copied"
        $changed++
    }
}
if ($Apply) {
    Write-Output "Done: $changed file(s) copied. Review with git status and git diff, then commit."
}
