# 交付产物：APK + 交接文档 + 源码；并清理上一版、回收长时间无响应的虚拟机
#
# 用户要求：
#   1. 每回构建新版本，输出 apk 的同时输出**交接文档和源码**；
#   2. 删除**上个版本**的交接文档和源码，防止堆积；
#   3. 输出文件后检索是否有**长时间无响应、占用过多内存的虚拟机**，有就结束它。
#
# 用法：
#   pwsh -File tool\deliver_release.ps1 -Version 1.20.3
#   pwsh -File tool\deliver_release.ps1 -Version 1.20.3 -SkipBuild   # 复用已构建的 APK
#
# 产物都放到桌面（用户实际取用的地方）：
#   桃花源阅读器-<版本>.apk
#   桃花源阅读器-<版本>-交接文档.md
#   桃花源阅读器-<版本>-源码.zip
#   APK-校验和.txt
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [switch]$SkipBuild,
  # 虚拟机内存阈值（MB）：超过这个数且「长时间无响应」就结束
  [int]$VmMemoryMb = 800,
  # 虚拟机 CPU 时间下限（秒）：低于它说明刚起来、还在干活，不动
  [int]$VmIdleSeconds = 120
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$desktop = [Environment]::GetFolderPath('Desktop')
# flutter build 把包放在 build/ 下；dist/ 是我们自己的归档副本
$builtApk = Join-Path $root 'build\app\outputs\flutter-apk\app-release.apk'
$apkSource = Join-Path $root "dist\tts_reader-v$Version-release.apk"

function Step([string]$text) { Write-Host "`n=== $text" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 1) 构建
Step "[1/5] 构建 release APK"
if ($SkipBuild) {
  Write-Host "      跳过构建（-SkipBuild）"
} else {
  Push-Location $root
  try {
    # flutter 会往 stderr 写「Flutter assets will be downloaded…」这类提示，
    # 在 $ErrorActionPreference='Stop' 下会被当成终止错误。
    # 所以这里临时放宽，只看退出码。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & flutter --no-version-check build apk --release
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($code -ne 0) { throw "flutter build apk 失败（exit $code）" }
  } finally { Pop-Location }
  # 构建缓存只保留最新一份（工作区规则）
  & (Join-Path $root 'tool\prune_flutter_build_cache.ps1') | Out-Host
}

if (-not (Test-Path $builtApk)) { throw "没找到构建产物：$builtApk" }

# ------------------------------------------------ 资源自检（P0，必须过）
# 2026-10-13 真事故：未 clean 的构建报成功、exit 0，但整个 assets/flutter_assets/
# 没有进包（真机启动即抛 Asset 'shaders/ink_sparkle.frag' not found，
# 字体 / 图标 / AssetManifest 也全缺）。所以交付前必须过这一关。
# 详见 tool\verify_apk_assets.ps1 的文件头。
Step "[1.2/5] APK 资源自检"
$prevEapVerify = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& (Join-Path $root 'tool\verify_apk_assets.ps1') -Apk $builtApk | Out-Host
$verifyCode = $LASTEXITCODE
$ErrorActionPreference = $prevEapVerify
if ($verifyCode -ne 0) {
  throw "APK 资源自检未通过（exit $verifyCode）：这个包不能交付。先 flutter clean 再重建。"
}

# ---------------------------------------------- 源码快照（回退用）
# 必须在归档 APK 之前就打好：这是「以后能回退到这一版」的唯一保障。
# 1.20.0 就是没留源码，回退时只能靠抠 APK 字符串重实现 —— 别再来一次。
Step "[1.5/5] 保存源码快照"
& (Join-Path $root 'tool\snapshot_source.ps1') -Version $Version | Out-Host

# 归档到 dist/，但**绝不覆盖同名文件**。
#
# ⚠️ 这条规则是踩过坑加的：`dist/` 里存着历史版本的**原始构建产物**，
# 那是唯一能拿回某个旧版本二进制的地方。有一次用同一个版本号重新构建
# （回退到 1.20.0 后重打包），这一步直接把 dist 里那份**真品 1.20.0**
# 覆盖掉了，不可恢复 —— 用户手上就只剩重建版了。
# 所以：目标已存在就换成带时间戳的名字，两份都留着。
if (Test-Path $apkSource) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $apkSource = Join-Path $root "dist\tts_reader-v$Version-release-$stamp.apk"
  Write-Host "      dist 里已有同版本包，这份另存为：$(Split-Path $apkSource -Leaf)" -ForegroundColor Yellow
}
Copy-Item $builtApk $apkSource -Force

# ------------------------------------------------- 2) 清理上一版（先删后写）
Step "[2/5] 清理上一版交付物"
# 用**宽**通配：交付物有四类（apk / 交接文档 / README / 源码），
# 之前只列了「交接文档.md」和「源码.zip」，README 与「交接文档-补充.md」
# 漏在桌面上堆积过。这里一律按「桃花源阅读器-*」清，只保本版本。
$patterns = @(
  '桃花源阅读器-*.apk',
  '桃花源阅读器-*.md',
  '桃花源阅读器-*.zip'
)
$removed = @()
foreach ($pattern in $patterns) {
  Get-ChildItem $desktop -Filter $pattern -File -ErrorAction SilentlyContinue | ForEach-Object {
    # 只删「不是本版本」的
    if ($_.Name -notmatch [regex]::Escape($Version)) {
      Remove-Item $_.FullName -Force
      $removed += $_.Name
    }
  }
}
if ($removed.Count -gt 0) {
  $removed | Sort-Object | ForEach-Object { Write-Host "      删除旧版：$_" }
} else {
  Write-Host "      没有需要删除的旧版产物"
}

# ------------------------------------------------------------- 3) 复制 APK
Step "[3/5] 输出 APK"
$apkDest = Join-Path $desktop "桃花源阅读器-$Version.apk"
Copy-Item $apkSource $apkDest -Force
$apkHash = (Get-FileHash $apkDest -Algorithm SHA256).Hash
$apkMb = [math]::Round((Get-Item $apkDest).Length / 1MB, 1)
Write-Host "      $apkDest  ($apkMb MB)"
Write-Host "      SHA-256 $apkHash"

# --------------------------------------------------------- 4) 交接文档
Step "[4/5] 输出交接文档"
$docs = @(
  @{ Src = 'HANDOFF.md'; Name = '交接文档' },
  @{ Src = 'README.md';  Name = 'README' },
  @{ Src = 'docs\交接文档.md'; Name = '交接文档-补充' }
)
$docNames = @()
foreach ($doc in $docs) {
  $src = Join-Path $root $doc.Src
  if (-not (Test-Path $src)) { Write-Host "      跳过（不存在）：$($doc.Src)"; continue }
  $dest = Join-Path $desktop "桃花源阅读器-$Version-$($doc.Name).md"
  Copy-Item $src $dest -Force
  $docNames += (Split-Path $dest -Leaf)
  Write-Host "      $(Split-Path $dest -Leaf)  ($([math]::Round((Get-Item $dest).Length/1KB,1)) KB)"
}

# ------------------------------------------------------------- 5) 源码包
Step "[5/5] 打包源码"
# 5.0) 源码的 **Markdown 版**（用户要求：源码和交接文档都要 md 格式）
#
# 用户实际是拿手机/纯文本阅读器看这些交付物的 —— zip 里的源码他打不开，
# 所以每版除了 zip 还要出一份「整包源码拼成一个大 md」（带目录 + 代码块）。
# 生成器：tool\export_source_md.js（随包发布，不含 HANDOFF.md / docs 内部文档）
$srcMd = Join-Path $desktop "桃花源阅读器-$Version-源码.md"
$exportJs = Join-Path $root 'tool\export_source_md.js'
if (Test-Path $exportJs) {
  $node = $null
  foreach ($cand in @('node', "$env:ProgramFiles\nodejs\node.exe",
      'C:\Users\user\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe')) {
    if ($cand -eq 'node') {
      $cmd = Get-Command node -ErrorAction SilentlyContinue
      if ($cmd) { $node = $cmd.Source; break }
    } elseif (Test-Path $cand) { $node = $cand; break }
  }
  if (-not $node) {
    Write-Host "      ⚠️ 找不到 node，跳过源码 md（zip 仍然有）" -ForegroundColor Yellow
  } else {
    & $node $exportJs $root $srcMd | Out-Host
    if (Test-Path $srcMd) {
      Write-Host "      $(Split-Path $srcMd -Leaf)  ($([math]::Round((Get-Item $srcMd).Length/1MB,2)) MB)"
      $docNames += (Split-Path $srcMd -Leaf)
    }
  }
} else {
  Write-Host "      ⚠️ 缺 tool\export_source_md.js，跳过源码 md" -ForegroundColor Yellow
}

# 复用 pack_release 的白名单规则：只发能公开的部分，不带 build/dist/签名等
$stage = Join-Path $env:TEMP "tts_reader-$Version-source"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$publish = @('analysis_options.yaml','pubspec.yaml','pubspec.lock','README.md','HANDOFF.md',
             'lib','android','test','integration_test','tool','docs')
$excludeDirs = @('.dart_tool','build','dist','release','.gradle','.idea','.vscode')
$excludeFiles = @('*.iml','local.properties','.flutter-plugins','.flutter-plugins-dependencies',
                  '*.jks','*.keystore','*.log','gradle-wrapper.jar')
$stageRoot = Join-Path $stage "tts_reader-$Version"
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
foreach ($item in Get-ChildItem $root -Force) {
  if ($publish -notcontains $item.Name) { continue }
  $target = Join-Path $stageRoot $item.Name
  if ($item.PSIsContainer) {
    $rcArgs = @($item.FullName, $target, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1',
                '/XD') + $excludeDirs + @('/XF') + $excludeFiles
    robocopy @rcArgs | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "robocopy 失败：$($item.Name) exit $LASTEXITCODE" }
  } else {
    Copy-Item $item.FullName $target -Force
  }
}
$zipDest = Join-Path $desktop "桃花源阅读器-$Version-源码.zip"
if (Test-Path $zipDest) { Remove-Item $zipDest -Force }
Compress-Archive -Path $stageRoot -DestinationPath $zipDest -CompressionLevel Optimal
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "      $(Split-Path $zipDest -Leaf)  ($([math]::Round((Get-Item $zipDest).Length/1MB,1)) MB)"

# --------------------------------------------------------- 校验和文件
$sumLines = @(
  "桃花源阅读器 $Version",
  "",
  "$apkHash  桃花源阅读器-$Version.apk",
  "",
  "校验方法：",
  "  Windows : Get-FileHash .\桃花源阅读器-$Version.apk -Algorithm SHA256",
  "  Linux   : sha256sum 桃花源阅读器-$Version.apk",
  "",
  "本次交付：",
  "  桃花源阅读器-$Version.apk            （安装包，$apkMb MB）"
)
$sumLines += $docNames | ForEach-Object { "  $_" }
$sumLines += "  桃花源阅读器-$Version-源码.zip        （源码）"
[System.IO.File]::WriteAllLines((Join-Path $desktop 'APK-校验和.txt'), $sumLines,
  (New-Object System.Text.UTF8Encoding($false)))

# ------------------------------------------- 回收无响应的虚拟机
Step "回收长时间无响应的虚拟机"
$vmNames = @('qemu-system-x86_64-headless','qemu-system-x86_64','emulator','qemu-system-aarch64-headless')
$killed = 0
foreach ($name in $vmNames) {
  Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
    $proc = $_
    $mb = [math]::Round($proc.WorkingSet64 / 1MB)
    $cpuSec = [math]::Round($proc.CPU)
    $idleSec = [math]::Round(((Get-Date) - $proc.StartTime).TotalSeconds)
    $responding = $proc.Responding
    $info = "$($proc.Name) pid=$($proc.Id) ${mb}MB CPU=${cpuSec}s 存活=${idleSec}s 响应=$responding"
    # 「长时间无响应且占用过多内存」才结束：刚起来的、还在干活的不动
    if (-not $responding -and $mb -ge $VmMemoryMb -and $idleSec -ge $VmIdleSeconds) {
      Write-Host "      结束无响应虚拟机：$info" -ForegroundColor Yellow
      Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
      $killed++
    } else {
      Write-Host "      保留：$info"
    }
  }
}
if ($killed -eq 0) { Write-Host "      没有需要结束的虚拟机" }

$os = Get-CimInstance Win32_OperatingSystem
Write-Host "      当前可用内存：$([math]::Round($os.FreePhysicalMemory/1MB,1)) GB / $([math]::Round($os.TotalVisibleMemorySize/1MB,1)) GB"

# ------------------------------------------- 回收 Gradle 守护进程
# 构建完一轮后 Gradle daemon 会一直挂着（实测 3.6 GB）。它不影响下次构建
# （下次会自动重启一个），但会把内存吃到只剩 1 GB 级 ——
# 之后跑测试就会 OOM（本项目实际踩过：Dart VM "Out of memory"）。
Step "回收 Gradle 守护进程"
$gradleKilled = 0
Get-Process -Name java -ErrorAction SilentlyContinue | ForEach-Object {
  $proc = $_
  $mb = [math]::Round($proc.WorkingSet64 / 1MB)
  if ($mb -lt 400) { return }
  $cmd = ''
  try { $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)").CommandLine } catch { }
  if ($cmd -match 'gradle') {
    Write-Host "      结束 Gradle 进程：pid=$($proc.Id) ${mb}MB" -ForegroundColor Yellow
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    $gradleKilled++
  }
}
if ($gradleKilled -eq 0) { Write-Host "      没有需要结束的 Gradle 进程" }

$os2 = Get-CimInstance Win32_OperatingSystem
Write-Host "      回收后可用内存：$([math]::Round($os2.FreePhysicalMemory/1MB,1)) GB / $([math]::Round($os2.TotalVisibleMemorySize/1MB,1)) GB"

Write-Host "`n完成。" -ForegroundColor Green
