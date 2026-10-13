# prune_flutter_build_cache.ps1
#
# Keep only the NEWEST Flutter build-cache directory under
# <project>\.dart_tool\flutter_build\ and delete the older ones.
#
# Each fingerprint directory there is the byproduct of one build
# (~0.16 GB: app.dill + program.dill and friends). They are regenerable:
# deleting them costs one slower next build, nothing else.
#
# Usage:
#   pwsh -File tool\prune_flutter_build_cache.ps1              # prune, keep newest
#   pwsh -File tool\prune_flutter_build_cache.ps1 -DryRun      # report only
#   pwsh -File tool\prune_flutter_build_cache.ps1 -Force       # prune even if dart is running
#
# NOTE: keep this file ASCII-only. A BOM-less UTF-8 file with non-ASCII text is
# decoded with the system code page by Windows PowerShell and can swallow a line.

[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [switch]$DryRun,
    [switch]$Force
)

if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }

$fb = Join-Path $ProjectRoot '.dart_tool\flutter_build'
if (-not (Test-Path -LiteralPath $fb)) {
    Write-Output "no flutter_build cache directory at: $fb"
    exit 0
}

# Refuse to run in the middle of a build: the tool would be writing into its cache.
if (-not $Force) {
    $busy = @(Get-Process -Name dart, flutter_tester -ErrorAction SilentlyContinue)
    if ($busy.Count -gt 0) {
        Write-Output "ABORT: a dart/flutter process is running (pid: $($busy.Id -join ', ')). Re-run with -Force to override."
        exit 2
    }
}

$dirs = @(Get-ChildItem -LiteralPath $fb -Directory -Force | Sort-Object LastWriteTime -Descending)
if ($dirs.Count -eq 0) {
    Write-Output "nothing to prune: no build-cache directories under $fb"
    exit 0
}

$keep = $dirs[0]
if ($dirs.Count -eq 1) {
    Write-Output "nothing to prune: only one cache directory present."
    Write-Output ("keep: {0}  [{1}]" -f $keep.Name, $keep.LastWriteTime)
    exit 0
}

$stale = $dirs[1..($dirs.Count - 1)]
$bytes = 0
foreach ($d in $stale) {
    $bytes += (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
               Measure-Object -Sum Length).Sum
}

Write-Output ("keep:  {0}  [{1}]" -f $keep.Name, $keep.LastWriteTime)
Write-Output ("prune: {0} older cache dir(s), {1:N2} GB" -f $stale.Count, ($bytes / 1GB))

if ($DryRun) {
    foreach ($d in $stale) { Write-Output ("  would delete: {0}  [{1}]" -f $d.Name, $d.LastWriteTime) }
    Write-Output "dry run: nothing was deleted."
    exit 0
}

foreach ($d in $stale) {
    Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

$left = @(Get-ChildItem -LiteralPath $fb -Directory -Force)
$freed = $bytes - (Get-ChildItem -LiteralPath $fb -Recurse -File -Force -ErrorAction SilentlyContinue |
                   Measure-Object -Sum Length).Sum
Write-Output ("done: removed {0}, remaining cache dir(s): {1}, freed {2:N2} GB" -f $stale.Count, $left.Count, ($freed / 1GB))
if ($left.Count -gt 1) {
    Write-Output "WARN: more than one cache directory remains (some files may have been locked)."
    exit 1
}
exit 0
