# LAME（MP3 编码器）的 Android 构建脚本（★v1.21.45 改动 5）
#
# 产出：`liblame.so` —— 里面是 **LAME 3.100 核心 + 我们的 JNI 薄包装**
# （见同目录的 `lame_jni.c`）。这个 .so 会被编译进 APK 的
# `lib/<abi>/liblame.so`，由 Kotlin 侧 `System.loadLibrary("lame")` 加载。
#
# ## 用法
#
# ```powershell
# # 一次性（或换 NDK / 换 LAME 版本后重跑）：编译并放进 jniLibs
# .\tool\build_lame.ps1
#
# # 只编某一个 ABI（调试用）
# .\tool\build_lame.ps1 -Abis arm64-v8a
# ```
#
# 脚本自己会：
# 1. 下载 **LAME 3.100 官方源码**（Debian 源里的 orig.tar.gz，带 SHA-256 校验）
#    到 `C:\ttsbuild\lame`（可用 `-WorkDir` 改）；
# 2. 用 Android NDK 的 CMake 工具链分别编 3 个 ABI；
# 3. 把 `liblame.so` 拷到 `android/app/src/main/jniLibs/<abi>/`。
#
# ## 许可（LGPL-2.0）
#
# LAME 是 LGPL-2.0：**动态链接**（独立 .so）即可合规发布，本项目正是这么做的；
# 源码与编译方式都留在仓库里（本脚本 + `cpp/CMakeLists.txt` + `cpp/lame_jni.c`），
# 满足"使用者能替换 / 重新链接 LAME"的要求。
# LAME 官方：https://lame.sourceforge.io/

[CmdletBinding()]
param(
    # 要编的 ABI（默认三个都编）
    [string[]]$Abis = @('arm64-v8a', 'armeabi-v7a', 'x86_64'),
    # LAME 源码与中间产物的存放目录
    [string]$WorkDir = 'C:\ttsbuild\lame',
    # Android SDK / NDK 位置（默认取环境变量，再退回 C:\ttsbuild\android-sdk）
    [string]$AndroidSdk = $(if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { 'C:\ttsbuild\android-sdk' }),
    [string]$NdkVersion = '25.1.8937393',
    # 已解包好的 LAME 源码根目录（给了就跳过下载）
    [string]$LameSrc = '',
    # 只配置不编译（排错用）
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# LAME 3.100 官方源码（Debian pool 的 orig.tar.gz —— SourceForge 的直链
# 在部分网络下会返回 HTML 登录页，这里用更稳的镜像）
$LameUrl = 'https://deb.debian.org/debian/pool/main/l/lame/lame_3.100.orig.tar.gz'
# SHA-256：2026-10 实测值（Debian pool 上的 lame_3.100.orig.tar.gz）；
# 对不上就说明拿到的不是同一份源码，必须停下来确认后再继续
$LameSha256 = 'DDFE36CAB873794038AE2C1210557AD34857A4B6BDC515785D1DA9E175B1DA1E'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$cppDir = Join-Path $repoRoot 'android\app\src\main\cpp'
$jniRoot = Join-Path $repoRoot 'android\app\src\main\jniLibs'

Write-Host "== LAME for Android ==" -ForegroundColor Cyan
Write-Host " 仓库：$repoRoot"
Write-Host " 工作目录：$WorkDir"
Write-Host " SDK：$AndroidSdk"
Write-Host " ABI：$($Abis -join ', ')"

if (-not (Test-Path (Join-Path $cppDir 'CMakeLists.txt'))) {
    throw "找不到 $cppDir\CMakeLists.txt"
}

# ---------------------------------------------------------------- 1. 源码
if ([string]::IsNullOrWhiteSpace($LameSrc)) {
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $tarball = Join-Path $WorkDir 'lame-3.100.tar.gz'
    $extract = Join-Path $WorkDir 'lame-src'

    $needDownload = $true
    if (Test-Path $tarball) {
        $hash = (Get-FileHash $tarball -Algorithm SHA256).Hash
        if ($hash -ne $LameSha256) {
            Write-Host " 已有的 tar 包校验不符（$hash），重新下载" -ForegroundColor Yellow
        } else {
            $needDownload = $false
        }
    }
    if ($needDownload) {
        Write-Host " 下载 LAME 3.100 ..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $LameUrl -OutFile $tarball -TimeoutSec 300 -UseBasicParsing
        $hash = (Get-FileHash $tarball -Algorithm SHA256).Hash
        if ($hash -ne $LameSha256) {
            throw "LAME 源码 SHA-256 不符：期望 $LameSha256，实际 $hash（网络被劫持 / 上游换包都要停下来查）"
        }
    } else {
        Write-Host " 复用已下载的 tar 包（校验通过）" -ForegroundColor Green
    }

    $srcRoot = Join-Path $extract 'lame-3.100'
    if (-not (Test-Path (Join-Path $srcRoot 'libmp3lame'))) {
        if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $extract | Out-Null
        Write-Host " 解包 ..."
        & "$env:SystemRoot\System32\tar.exe" -xzf $tarball -C $extract
        if ($LASTEXITCODE -ne 0) { throw "解包失败（tar 退出码 $LASTEXITCODE）" }
    }
    $LameSrc = $srcRoot
}

if (-not (Test-Path (Join-Path $LameSrc 'libmp3lame\version.h'))) {
    throw "LAME 源码目录不对：$LameSrc"
}
$verLine = Select-String -Path (Join-Path $LameSrc 'libmp3lame\version.h') -Pattern 'LAME_MINOR_VERSION' |
    Select-Object -First 1
Write-Host " LAME 源码：$LameSrc（$($verLine.Line.Trim())）" -ForegroundColor Green
if ($verLine.Line -notmatch '\b100\b') {
    Write-Host " ⚠️ 这不是 3.100（施工单要求 3.100）—— 请确认后再继续" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 2. 工具链
$cmake = Join-Path $AndroidSdk 'cmake\3.18.1\bin\cmake.exe'
if (-not (Test-Path $cmake)) {
    $found = Get-ChildItem (Join-Path $AndroidSdk 'cmake') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($found) { $cmake = Join-Path $found.FullName 'bin\cmake.exe' }
}
if (-not (Test-Path $cmake)) { throw "找不到 cmake.exe（在 $AndroidSdk\cmake 下）" }

$toolchain = Join-Path $AndroidSdk "ndk\$NdkVersion\build\cmake\android.toolchain.cmake"
if (-not (Test-Path $toolchain)) {
    $ndkDir = Get-ChildItem (Join-Path $AndroidSdk 'ndk') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($ndkDir) { $toolchain = Join-Path $ndkDir.FullName 'build\cmake\android.toolchain.cmake' }
}
if (-not (Test-Path $toolchain)) { throw "找不到 NDK 的 cmake 工具链（$toolchain）" }

# ⚠️ 生成器必须显式指定 Ninja：CMake 在 Windows 上默认挑 "NMake Makefiles"，
# 而这台机器没有 nmake → 连"编译器能不能编个 helloworld"都过不去
# （第一版就卡在这里）。Ninja 随 Android SDK 的 cmake 包一起提供。
$ninja = Join-Path (Split-Path $cmake -Parent) 'ninja.exe'
if (-not (Test-Path $ninja)) { throw "找不到 ninja.exe（$ninja）" }
Write-Host " cmake：$cmake"
Write-Host " ninja：$ninja"
Write-Host " NDK 工具链：$toolchain"

# ---------------------------------------------------------------- 3. 编译
$androidAbi = @{
    'arm64-v8a'   = 'arm64-v8a'
    'armeabi-v7a' = 'armeabi-v7a'
    'x86_64'      = 'x86_64'
}

$results = @()
foreach ($abi in $Abis) {
    if (-not $androidAbi.ContainsKey($abi)) { throw "不认识的 ABI：$abi" }
    $buildDir = Join-Path $WorkDir "build\$abi"
    $stageDir = Join-Path $WorkDir "stage\$abi"
    Write-Host "== 编 $abi ==" -ForegroundColor Cyan

    # ⚠️ 变量名**不能**叫 `$args` —— 那是 PowerShell 的自动变量（当前脚本的参数数组），
    # 赋值会被忽略，cmake 会一个参数都收不到（本脚本第一版就栽在这里）。
    $cmakeArgs = @(
        '-S', $cppDir,
        '-B', $buildDir,
        # 显式 Ninja（见上面的说明：默认的 NMake 在这台机器上不能用）
        '-G', 'Ninja',
        "-DCMAKE_MAKE_PROGRAM=$ninja",
        "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
        "-DANDROID_ABI=$abi",
        '-DANDROID_PLATFORM=android-21',
        '-DCMAKE_BUILD_TYPE=Release',
        # ⚠️ 反斜杠路径要转成 /：CMake 会把 `C:\a\b` 当转义序列
        # （报 Invalid character escape '\l'）—— CMakeLists 里也做了 TO_CMAKE_PATH 兜底
        "-DLAME_SRC=$($LameSrc -replace '\\', '/')",
        "-DCMAKE_LIBRARY_OUTPUT_DIRECTORY=$stageDir"
    )
    if ($DryRun) {
        Write-Host "  （-DryRun）$cmake $($cmakeArgs -join ' ')" -ForegroundColor Yellow
        continue
    }

    # 换生成器 / 换 NDK 后旧缓存会让 cmake 直接报错 → 每次都从干净目录开始
    if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }

    # ⚠️ 原生程序往 stderr 写东西时（cmake 的 deprecation warning 就是），
    # `$ErrorActionPreference = 'Stop'` 会把警告当致命错误 → 这两步临时降级，
    # 只认 `$LASTEXITCODE`。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $cmake @cmakeArgs 2>&1 |
        Where-Object { "$_" -notmatch 'System\.Management\.Automation\.RemoteException' } |
        ForEach-Object { Write-Host "   $_" }
    $cfgCode = $LASTEXITCODE
    if ($cfgCode -eq 0) {
        & $cmake --build $buildDir --config Release -- -j 4 2>&1 |
            Where-Object { "$_" -notmatch 'System\.Management\.Automation\.RemoteException' } |
            ForEach-Object { Write-Host "   $_" }
        $buildCode = $LASTEXITCODE
    } else {
        $buildCode = -1
    }
    $ErrorActionPreference = $prevEap
    if ($cfgCode -ne 0) { throw "cmake 配置失败（$abi，退出码 $cfgCode）" }
    if ($buildCode -ne 0) { throw "编译失败（$abi，退出码 $buildCode）" }

    $so = Join-Path $stageDir 'liblame.so'
    if (-not (Test-Path $so)) { throw "没生成 liblame.so（$abi）" }
    $destDir = Join-Path $jniRoot $abi
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    Copy-Item $so (Join-Path $destDir 'liblame.so') -Force
    $size = [math]::Round((Get-Item (Join-Path $destDir 'liblame.so')).Length / 1KB, 1)
    Write-Host " ✅ $abi → jniLibs\$abi\liblame.so（$size KB）" -ForegroundColor Green
    $results += [pscustomobject]@{ Abi = $abi; KB = $size }
}

if (-not $DryRun) {
    Write-Host "== 完成 ==" -ForegroundColor Cyan
    $results | Format-Table -AutoSize
    Write-Host " 记得跑一遍： .\tool\verify_apk_lame.ps1 <apk>（出包后校验三个 ABI 都在）" -ForegroundColor Yellow
}
