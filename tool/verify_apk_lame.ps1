# verify_apk_lame.ps1 - refuse to deliver an APK whose bundled LAME (MP3 encoder) is incomplete.
#
# WHY THIS EXISTS (2026-10-13, v1.21.45)
#
#   The MP3 export feature links a native library, `liblame.so`, built by
#   tool\build_lame.ps1 and committed under android\app\src\main\jniLibs\<abi>\.
#   Three things can silently go wrong and NONE of them fails the Gradle build:
#
#     1. the .so was never built (jniLibs empty) -> APK has no liblame.so,
#        System.loadLibrary("lame") throws, export quietly falls back to WAV;
#     2. only arm64-v8a was built (the usual shortcut) -> 32-bit phones lose MP3;
#     3. the file is there but zero-length / truncated -> UnsatisfiedLinkError.
#
#   In all three cases `flutter build apk --release` prints BUILD SUCCESSFUL and
#   exits 0. This script is the missing evidence. Run it before delivering.
#
# USAGE
#   pwsh -File tool\verify_apk_lame.ps1 -Apk dist\tts_reader-v1.21.45-test05.apk
#   exit code 0 = OK, 1 = do not deliver
#
# NOTE: keep this file ASCII-only (a BOM-less UTF-8 .ps1 is read as ANSI by
# Windows PowerShell and can swallow the next line).

param(
  [Parameter(Mandatory = $true)][string]$Apk,
  # Abis that must be present. Keep in sync with tool\build_lame.ps1 -Abis.
  [string[]]$Abis = @('arm64-v8a', 'armeabi-v7a', 'x86_64'),
  # A stripped liblame.so is ~900 KB (armeabi-v7a) .. ~1.2 MB (arm64/x86_64).
  # Measured 2026-10-13 (v1.21.45 / LAME 3.100 / NDK 25.1) - sizes INSIDE the APK:
  #   arm64-v8a 179.7 KB | armeabi-v7a 142.5 KB | x86_64 210.8 KB
  # NOTE these are much smaller than the files under jniLibs\ (900 KB .. 1.2 MB):
  # the packaging step STRIPS the native library, so ~1/6 is expected. A stub or
  # truncated build lands far below this, hence the floor.
  [int]$MinBytes = 80000,
  # When set, the APK must NOT carry any liblame.so (used for WAV-only builds).
  [switch]$ExpectAbsent
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Test-Path -LiteralPath $Apk)) { throw "APK not found: $Apk" }
$full = (Resolve-Path -LiteralPath $Apk).Path

$zip = [System.IO.Compression.ZipFile]::OpenRead($full)
try {
  $entries = @($zip.Entries | Where-Object { $_.FullName -like 'lib/*/liblame.so' })

  Write-Host ("verify_apk_lame: {0}" -f (Split-Path -Leaf $full))

  if ($ExpectAbsent) {
    if ($entries.Count -gt 0) {
      Write-Host ("  liblame.so present ({0}) but -ExpectAbsent was given" -f $entries.Count) -ForegroundColor Red
      Write-Host "  RESULT: FAIL - DO NOT DELIVER THIS APK" -ForegroundColor Red
      exit 1
    }
    Write-Host "  liblame.so             : absent (expected)"
    Write-Host "  RESULT: OK" -ForegroundColor Green
    exit 0
  }

  $found = @{}
  foreach ($e in $entries) {
    # lib/<abi>/liblame.so
    $parts = $e.FullName.Split('/')
    if ($parts.Length -ge 3) { $found[$parts[1]] = $e.Length }
  }

  $bad = @()
  foreach ($abi in $Abis) {
    if (-not $found.ContainsKey($abi)) {
      Write-Host ("  {0,-13}: MISSING" -f $abi) -ForegroundColor Red
      $bad += $abi
      continue
    }
    $len = [int]$found[$abi]
    $kb = [math]::Round($len / 1KB, 1)
    if ($len -lt $MinBytes) {
      Write-Host ("  {0,-13}: {1} KB  TOO SMALL (min {2} KB)" -f $abi, $kb, [math]::Round($MinBytes / 1KB)) -ForegroundColor Red
      $bad += $abi
    } else {
      Write-Host ("  {0,-13}: {1} KB" -f $abi, $kb) -ForegroundColor Green
    }
  }

  # Anything extra is fine (future ABIs), but say so - it is evidence about what shipped.
  $extra = @($found.Keys | Where-Object { $Abis -notcontains $_ })
  if ($extra.Count -gt 0) { Write-Host ("  extra abi      : {0}" -f ($extra -join ', ')) }

  if ($bad.Count -gt 0) {
    Write-Host "  RESULT: FAIL - DO NOT DELIVER THIS APK" -ForegroundColor Red
    Write-Host "  hint: run tool\build_lame.ps1 (it builds all three ABIs into jniLibs)" -ForegroundColor Yellow
    Write-Host "        then rebuild: flutter clean; flutter build apk --release" -ForegroundColor Yellow
    exit 1
  }

  Write-Host "  RESULT: OK" -ForegroundColor Green
  exit 0
} finally {
  $zip.Dispose()
}
