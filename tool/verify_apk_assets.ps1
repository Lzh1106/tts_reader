# verify_apk_assets.ps1 - refuse to deliver an APK whose Flutter asset bundle is missing.
#
# WHY THIS EXISTS (2026-10-13, real incident)
#
#   A release APK was built WITHOUT `flutter clean`. `flutter build apk --release`
#   printed BUILD SUCCESSFUL and exited 0, and the build log even contained the
#   normal asset step ("Font asset MaterialIcons-Regular.otf was tree-shaken...").
#   But the whole `assets/flutter_assets/` tree was missing from the APK:
#
#     flutter_assets entries : 0   (a healthy package has 16)
#
#   On a real phone the app started (libapp.so and the dex files were fine) and
#   then threw, twice in a row:
#     [uncaught] Exception: Asset 'shaders/ink_sparkle.frag' not found
#   Fonts, Material icons, FontManifest and AssetManifest were missing too.
#
#   "exit code 0" and "build succeeded" are therefore NOT evidence that the
#   package is usable. This script is that missing evidence. Run it before
#   handing an APK to anyone.
#
# USAGE
#   pwsh -File tool\verify_apk_assets.ps1 -Apk dist\tts_reader-v1.21.42-release.apk
#   exit code 0 = OK, 1 = do not deliver
#
# NOTE: keep this file ASCII-only (a BOM-less UTF-8 .ps1 is read as ANSI by
# Windows PowerShell and can swallow the next line).

param(
  [Parameter(Mandatory = $true)][string]$Apk,
  # A healthy bundle in this project has 16 entries; allow some drift downwards
  # but never zero. Raise/lower only with a measured reason.
  [int]$MinEntries = 12
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Test-Path -LiteralPath $Apk)) { throw "APK not found: $Apk" }
$full = (Resolve-Path -LiteralPath $Apk).Path

# These three are the ones whose absence breaks the app in ways users notice
# immediately (no splash shader -> uncaught exception at startup; no font
# manifest -> Material icons render as boxes; no AssetManifest -> every
# rootBundle.load fails).
$must = @(
  'assets/flutter_assets/AssetManifest.bin',
  'assets/flutter_assets/FontManifest.json',
  'assets/flutter_assets/shaders/ink_sparkle.frag'
)

$zip = [System.IO.Compression.ZipFile]::OpenRead($full)
try {
  $names = @($zip.Entries | ForEach-Object { $_.FullName })
  $assets = @($names | Where-Object { $_ -like 'assets/flutter_assets/*' })
  $libs = @($names | Where-Object { $_ -like 'lib/*/libapp.so' })
  $missing = @($must | Where-Object { $names -notcontains $_ })

  Write-Host ("verify_apk_assets: {0}" -f (Split-Path -Leaf $full))
  Write-Host ("  flutter_assets entries : {0} (minimum {1})" -f $assets.Count, $MinEntries)
  Write-Host ("  libapp.so (per ABI)    : {0}" -f $libs.Count)
  if ($missing.Count -gt 0) {
    Write-Host "  MISSING:" -ForegroundColor Red
    foreach ($m in $missing) { Write-Host ("    {0}" -f $m) -ForegroundColor Red }
  }

  if ($assets.Count -lt $MinEntries -or $missing.Count -gt 0 -or $libs.Count -lt 1) {
    Write-Host "  RESULT: FAIL - DO NOT DELIVER THIS APK" -ForegroundColor Red
    Write-Host "  hint: rebuild with 'flutter clean' first (see the header of this file)" -ForegroundColor Yellow
    exit 1
  }

  Write-Host "  RESULT: OK" -ForegroundColor Green
  exit 0
} finally {
  $zip.Dispose()
}
