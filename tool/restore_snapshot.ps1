# 从**源码快照**还原到某个版本（回退用）
#
# 配套 tool\snapshot_source.ps1。存在的原因见那边：1.20.0 回退时发现源码没留，
# 只能靠抠 APK 字符串重新实现。以后要回退，直接还原对应版本的快照即可。
#
# 用法：
#   pwsh -File tool\restore_snapshot.ps1 -List                 # 看有哪些快照
#   pwsh -File tool\restore_snapshot.ps1 -Version 1.20.8       # 还原（会先备份当前源码）
#   pwsh -File tool\restore_snapshot.ps1 -Version 1.20.8 -DryRun
#
# 安全性：
# - 还原前把**当前**源码也打一份快照（pre-restore-<时间>），万一还原错了还能回来；
# - 只覆盖白名单里的源码路径，不碰 dist/ build/ release/ snapshots/；
# - 还原后提示需要跑 analyze / 测试 / 重新构建。
param(
  [string]$Version,
  [switch]$List,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$snapDir = Join-Path $root 'snapshots'
$snapTool = Join-Path $root 'tool\snapshot_source.ps1'

if ($List) { & $snapTool -List; exit 0 }

if (-not $Version) { throw "要指定版本：-Version 1.20.8（用 -List 看有哪些）" }
$Version = ($Version -split '\+')[0]
$zip = Join-Path $snapDir "tts_reader-v$Version-source.zip"
if (-not (Test-Path $zip)) {
  Write-Host "没有这个版本的快照：$zip" -ForegroundColor Red
  Write-Host "现有快照："
  & $snapTool -List
  exit 1
}

$manifest = Join-Path $snapDir "tts_reader-v$Version.manifest.txt"
if (Test-Path $manifest) {
  Write-Host "快照清单："
  Get-Content $manifest -Encoding UTF8 | ForEach-Object { "  $_" }
}
Write-Host ""

# 干跑：只报告会动哪些路径
$stage = Join-Path $env:TEMP "tts_restore_$Version"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $stage -Force
$stageRoot = Join-Path $stage "tts_reader-$Version"
if (-not (Test-Path $stageRoot)) {
  $candidate = Get-ChildItem $stage -Directory | Select-Object -First 1
  if ($candidate) { $stageRoot = $candidate.FullName }
}
if (-not (Test-Path $stageRoot)) { throw "快照内容不对：找不到根目录" }

$entries = Get-ChildItem $stageRoot -Force | Select-Object -ExpandProperty Name
Write-Host "快照包含：$($entries -join ', ')"
if ($DryRun) {
  Write-Host "`n-DryRun：已解压到 $stageRoot，未改动工作区。" -ForegroundColor Yellow
  exit 0
}

# 还原前先备份当前源码（用时间戳直接打包，不走 snapshot_source ——
# 那个按 pubspec 版本号命名，同版本会拒绝覆盖）
Write-Host "`n[1/3] 备份当前源码…"
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupZip = Join-Path $snapDir "tts_reader-vpre-restore-$stamp-source.zip"
New-Item -ItemType Directory -Path $snapDir -Force | Out-Null
$backupStage = Join-Path $env:TEMP "tts_pre_restore_$stamp"
$backupRoot = Join-Path $backupStage "tts_reader-pre-restore-$stamp"
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$srcEntries = @('analysis_options.yaml', 'pubspec.yaml', 'pubspec.lock', 'README.md',
                'HANDOFF.md', 'lib', 'android', 'test', 'integration_test', 'tool', 'docs')
$excludeDirs = @('.dart_tool', 'build', 'dist', 'release', 'snapshots', '.gradle',
                 '.idea', '.vscode')
$excludeFiles = @('*.iml', 'local.properties', '.flutter-plugins',
                  '.flutter-plugins-dependencies', '*.jks', '*.keystore', '*.log',
                  'gradle-wrapper.jar')
foreach ($name in $srcEntries) {
  $src = Join-Path $root $name
  if (-not (Test-Path $src)) { continue }
  $dst = Join-Path $backupRoot $name
  if ((Get-Item $src).PSIsContainer) {
    $rcArgs = @($src, $dst, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1',
                '/XD') + $excludeDirs + @('/XF') + $excludeFiles
    robocopy @rcArgs | Out-Null
  } else {
    Copy-Item $src $dst -Force
  }
}
Compress-Archive -Path $backupRoot -DestinationPath $backupZip -CompressionLevel Optimal
Remove-Item $backupStage -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "      已备份为 $(Split-Path $backupZip -Leaf)" -ForegroundColor Green

Write-Host "[2/3] 还原 $Version 的源码…"
# 只覆盖快照里有的顶层项：其余（dist/build/release/snapshots）保持不动
foreach ($name in $entries) {
  $src = Join-Path $stageRoot $name
  $dst = Join-Path $root $name
  if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
  if ((Get-Item $src).PSIsContainer) {
    Copy-Item $src $dst -Recurse -Force
  } else {
    Copy-Item $src $dst -Force
  }
  Write-Host "      $name"
}

Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

$ver = Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^version:' |
  Select-Object -First 1
Write-Host "`n[3/3] 完成。现在 pubspec 里是：$($ver.Line.Trim())" -ForegroundColor Green
Write-Host "下一步建议："
Write-Host "  cd tts_reader; flutter --no-version-check analyze"
Write-Host "  flutter --no-version-check test --concurrency=2"
Write-Host "  flutter --no-version-check build apk --release"
