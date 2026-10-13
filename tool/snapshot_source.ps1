# 给当前源码打一份**版本快照**，方便以后回退
#
# 为什么需要它：2026-10-08 回退到 1.20.0 时发现——**1.20.0 的源码根本没留**
# （只归档过 APK，git 里也只有 v1.15.0 一个提交）。结果「回退源码」只能靠
# 从 APK 里抠字符串 + 照文档重新实现，而且重新打包时还把那份真品 APK
# 覆盖掉了（同一个 dist 路径）。这份脚本就是为避免再发生这种事。
#
# 用法：
#   pwsh -File tool\snapshot_source.ps1                      # 用 pubspec.yaml 里的版本号
#   pwsh -File tool\snapshot_source.ps1 -Version 1.20.9      # 指定版本号
#   pwsh -File tool\snapshot_source.ps1 -List                # 列出已有快照
param(
  [string]$Version,
  [switch]$List,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$snapDir = Join-Path $root 'snapshots'

function Read-VersionFromPubspec {
  $pubspec = Join-Path $root 'pubspec.yaml'
  if (-not (Test-Path $pubspec)) { return $null }
  $line = Select-String -Path $pubspec -Pattern '^version:\s*(\S+)' |
    Select-Object -First 1
  if (-not $line) { return $null }
  return $line.Matches[0].Groups[1].Value
}

if ($List) {
  if (-not (Test-Path $snapDir)) { Write-Host "还没有任何快照（$snapDir）"; exit 0 }
  Write-Host "已有源码快照（$snapDir）："
  Get-ChildItem $snapDir -Filter '*.zip' | Sort-Object Name | ForEach-Object {
    $manifest = Join-Path $snapDir ($_.BaseName + '.manifest.txt')
    $note = ''
    if (Test-Path $manifest) {
      $v = (Get-Content $manifest -Encoding UTF8 |
        Where-Object { $_ -like 'version=*' } | Select-Object -First 1)
      if ($v) { $note = $v }
    }
    "  {0,-42} {1,8:N2} MB  {2}  {3}" -f $_.Name, ($_.Length / 1MB),
      $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $note
  }
  exit 0
}

if (-not $Version) { $Version = Read-VersionFromPubspec }
if (-not $Version) { throw "拿不到版本号：pubspec.yaml 里没有 version:，也没传 -Version" }
# 版本号里可能带 build 号（1.20.0+42）——快照名只用前半段
$Version = ($Version -split '\+')[0]

New-Item -ItemType Directory -Path $snapDir -Force | Out-Null
$zip = Join-Path $snapDir "tts_reader-v$Version-source.zip"
$manifestPath = Join-Path $snapDir "tts_reader-v$Version.manifest.txt"

# 已存在就不覆盖（同版本重打包时保留最早那份「当时真相」）
if (Test-Path $zip) {
  Write-Host "快照已存在，跳过：$(Split-Path $zip -Leaf)" -ForegroundColor Yellow
  Write-Host "（同版本重复打包时保留最早那份；要看这次改动请先升版本号）"
  exit 0
}

# 与 pack_release 一致的白名单：只收能公开的源码，不带构建产物与签名
$publish = @('analysis_options.yaml', 'pubspec.yaml', 'pubspec.lock', 'README.md',
             'HANDOFF.md', 'lib', 'android', 'test', 'integration_test', 'tool', 'docs')
$excludeDirs = @('.dart_tool', 'build', 'dist', 'release', 'snapshots', '.gradle',
                 '.idea', '.vscode')
$excludeFiles = @('*.iml', 'local.properties', '.flutter-plugins',
                  '.flutter-plugins-dependencies', '*.jks', '*.keystore', '*.log',
                  'gradle-wrapper.jar')

$stage = Join-Path $env:TEMP "tts_snapshot_$Version"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$stageRoot = Join-Path $stage "tts_reader-$Version"
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

foreach ($item in Get-ChildItem $root -Force) {
  if ($publish -notcontains $item.Name) { continue }
  $target = Join-Path $stageRoot $item.Name
  if ($item.PSIsContainer) {
    $rcArgs = @($item.FullName, $target, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP',
                '/R:1', '/W:1', '/XD') + $excludeDirs + @('/XF') + $excludeFiles
    robocopy @rcArgs | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "robocopy 失败：$($item.Name) exit $LASTEXITCODE" }
  } else {
    Copy-Item $item.FullName $target -Force
  }
}

# 清单：记下「这份快照是什么」——回退时靠它确认
$gitCommit = ''
$gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $gitExe -and (Test-Path 'C:\ttsbuild\git\cmd\git.exe')) {
  $gitExe = 'C:\ttsbuild\git\cmd\git.exe'
}
if (Test-Path $gitExe) {
  try {
    $gitCommit = (& $gitExe -C $root rev-parse --short HEAD 2>$null | Select-Object -First 1)
  } catch { }
}
$fileCount = @(Get-ChildItem $stageRoot -Recurse -File -Force).Count
$manifest = @(
  "version=$Version",
  "versionLine=$(Read-VersionFromPubspec)",
  "capturedAt=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
  "gitCommit=$gitCommit",
  "files=$fileCount",
  "note=源码快照，用于回退。解压后用 tool\restore_snapshot.ps1 还原。"
)
[System.IO.File]::WriteAllLines($manifestPath, $manifest,
  (New-Object System.Text.UTF8Encoding($false)))

Compress-Archive -Path $stageRoot -DestinationPath $zip -CompressionLevel Optimal
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

if (-not $Quiet) {
  Write-Host "已保存源码快照：$(Split-Path $zip -Leaf)  " -NoNewline
  Write-Host "($([math]::Round((Get-Item $zip).Length / 1MB, 2)) MB, $fileCount 个文件)" `
    -ForegroundColor Green
  Write-Host "      清单：$(Split-Path $manifestPath -Leaf)"
}
