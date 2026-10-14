# export_local_ca.ps1 —— 导出本机加速工具的根 CA，给 Node 用
#
# ## 为什么需要它
#
# 本机跑着 GitHub 加速工具（实测是 `steamcommunity_302.cli`，监听本机 443），
# 它用**自签 CA** 给 GitHub 域名签证书。于是：
#   * PowerShell 能访问 GitHub（走 Windows 证书库）
#   * **Node 的 fetch 会失败**：`fetch failed` / `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`
#
# 正确做法是把这个 CA 喂给 Node（`NODE_EXTRA_CA_CERTS`），**而不是关掉证书校验**。
# `tool/gh_sync_release.js` 会自动使用本脚本生成的 `build/local-ca.pem`
# （找不到时会提示你先跑本脚本）。
#
# 用法：
#   & .\tool\export_local_ca.ps1
#
# 产物：build\local-ca.pem（**不进仓库** —— build/ 已在 .gitignore 里）
# 注意：CA 轮换后要重新跑一次（工具更新时会换新根证书）。

[CmdletBinding()]
param(
  [string]$OutFile = (Join-Path $PSScriptRoot '..\build\local-ca.pem')
)

$ErrorActionPreference = 'Stop'

# 匹配本机加速工具的根证书。已知的两种命名：
#   CN=Steamcommunity302（含 "... - 2026 ECC Root" 变体）
#   CN=SteamTools Certificate（BeyondDimension，同厂另一工具）
$pattern = 'Steamcommunity302|SteamTools'

$certs = @(
  Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -match $pattern }
)

if ($certs.Count -eq 0) {
  Write-Output "没找到匹配 '$pattern' 的根 CA。"
  Write-Output '可能这台机器没有装加速工具 —— 那就直接用 node 跑同步脚本即可（它自会判断）。'
  exit 0
}

$dir = Split-Path -Parent $OutFile
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$sb = New-Object System.Text.StringBuilder
foreach ($c in $certs) {
  [void]$sb.AppendLine('# ' + $c.Subject)
  [void]$sb.AppendLine('-----BEGIN CERTIFICATE-----')
  [void]$sb.AppendLine([Convert]::ToBase64String($c.RawData, 'InsertLineBreaks'))
  [void]$sb.AppendLine('-----END CERTIFICATE-----')
}

# 不带 BOM：Node 读 PEM 时 BOM 会碍事
[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-Output "已导出 $($certs.Count) 张 CA → $OutFile"
$certs | ForEach-Object { Write-Output ("  · " + $_.Subject) }
Write-Output ''
Write-Output '提示：CA 轮换（加速工具更新）后重新跑一次本脚本即可。'
