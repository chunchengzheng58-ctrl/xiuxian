param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$repoPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
if (-not $OutputDirectory) { $OutputDirectory = [IO.Path]::GetFullPath((Join-Path $repoPath '../../outputs/commercial-preview/web')) }
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$manifest = Get-Content -LiteralPath (Join-Path $OutputDirectory 'manifest.json') -Raw | ConvertFrom-Json
if ($manifest.validation.state -ne 'passed') { throw 'Run export, pack audit, basic browser and online checks before packaging.' }
$instructions = @"
疯狂修仙，中 · Web 开发版

此包包含当前已验证的 Web 客户端，没有发布到在线站点。
请通过 HTTP 服务打开；直接双击 index.html 的 file:// 方式不能运行游戏。
正式登录、PVE、PVP、社交、交易与养成需要此版本匹配的 Node.js 24 后端。

在源码 server 目录启动独立试玩服务的 PowerShell 示例：
  npm.cmd ci
  npm.cmd run build
  `$env:HOST = '127.0.0.1'
  `$env:PORT = '8081'
  `$env:DATABASE_PATH = '../work/web-preview/game.sqlite'
  `$env:WEB_ROOT = '此包解压目录的绝对路径'
  `$env:CORS_ORIGINS = 'http://127.0.0.1:8081,http://localhost:8081'
  npm.cmd start
随后打开 http://127.0.0.1:8081/ 。此独立数据库不会自动包含其他服务器的账号。

已验证：交付 HTML 无测试桥的桌面/手机基础加载与输入；
两 Web 客户端真实 PVE、掉线同局恢复、首通奖励、抽卡、穿戴/强化、
带流派与强化等级的跨账号交易、好友申请/私信、好友 PVP、
公开排队/取消/自动入场、权威胜负与精确积分榜；
抽卡已结算但回执丢失后，低余额同页及刷新重登找回原请求，只有一次扣费。
这些联网测试只在临时测试 HTML/浏览器虚拟FS加载控制桥，交付文件没有测试桥。

尚未以此验证公网部署、弱网性能、长时间运营或手机实战手感。
文件 SHA-256 与源码指纹、详细验证范围见 manifest.json。
"@
Set-Content -LiteralPath (Join-Path $OutputDirectory 'PLAYTEST.txt') -Value $instructions -Encoding utf8
$zipPath = Join-Path $OutputDirectory 'commercial-web-preview.zip'
$included = @($manifest.files | ForEach-Object { Join-Path $OutputDirectory $_.name })
$included += Join-Path $OutputDirectory 'manifest.json'
$included += Join-Path $OutputDirectory 'PLAYTEST.txt'
$fontLicense = Join-Path $repoPath 'assets/fonts/OFL.txt'
if (Test-Path -LiteralPath $fontLicense) {
  $licenseOutput = Join-Path $OutputDirectory 'NotoSansSC-OFL.txt'
  Copy-Item -LiteralPath $fontLicense -Destination $licenseOutput -Force
  $included += $licenseOutput
}
Compress-Archive -LiteralPath $included -DestinationPath $zipPath -CompressionLevel Optimal -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
  foreach ($file in $manifest.files) {
    $entry = $archive.GetEntry($file.name)
    if ($null -eq $entry -or $entry.Length -ne $file.bytes) { throw "Missing or wrong-size export: $($file.name)" }
    $entryStream = $entry.Open()
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $actualHash = ([BitConverter]::ToString($algorithm.ComputeHash($entryStream))).Replace('-', '').ToLowerInvariant() }
    finally { $entryStream.Dispose(); $algorithm.Dispose() }
    if ($actualHash -ne $file.sha256) { throw "ZIP hash mismatch: $($file.name)" }
  }
  if ($null -eq $archive.GetEntry('manifest.json') -or $null -eq $archive.GetEntry('PLAYTEST.txt')) { throw 'Delivery metadata missing.' }
  $entryCount = $archive.Entries.Count
} finally { $archive.Dispose() }
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath ($zipPath + '.sha256') -Value ($zipHash + '  commercial-web-preview.zip') -Encoding ascii
$summary = [ordered]@{ zip = $zipPath; bytes = (Get-Item -LiteralPath $zipPath).Length; sha256 = $zipHash; entries = $entryCount; verifiedExportFiles = $manifest.files.Count; runtimeSourceFingerprint = $manifest.runtimeSourceFingerprint }
$summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'zip-audit.json') -Encoding utf8
$summary | ConvertTo-Json -Compress
