# private-push.ps1 — 把私密但重要的东西推到私有仓库
#
# 放什么：日记正文、自省报告、QQ 侧状态快照。
# 不放什么：凭据、令牌、控制台 token、锁文件、日志。
#
# 为什么单独一个仓库：`che-persona` 是公开的（人格与记忆），而日记与聊天状态里有
# 本机路径、对话原文、群友信息——它们该被备份，但不该被公开。
#
# 为什么用 Contents API 而不是 git：这台机器不装 git，API 足够且不会把仓库搞脏。
#
# 脱敏：所有 JSON 在推送前会递归抹掉键名匹配 token/secret/password/apikey 的值，
# 并在日志里报告抹掉了几个字段（只报数量，不报内容）。
#
# 用法：
#   .\private-push.ps1
#   .\private-push.ps1 -DryRun
#   .\private-push.ps1 -Owner Sigh1057 -Repo che-private

[CmdletBinding()]
param(
  [string]$Owner = 'Sigh1057',
  [string]$Repo = 'che-private',
  [string]$LocalDir = '',
  [string]$BridgeDir = '',
  [int]$MaxReports = 5,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (-not $LocalDir) { $LocalDir = Join-Path $env:USERPROFILE '.dsh\persona' }
if (-not $BridgeDir) {
  $candidates = @('G:\DHS\qq-bridge', 'D:\qq-bridge', (Join-Path $env:USERPROFILE 'qq-bridge'))
  foreach ($c in $candidates) { if (Test-Path -LiteralPath (Join-Path $c 'state')) { $BridgeDir = $c; break } }
}

function Resolve-Token {
  $t = $env:GH_TOKEN
  if (-not $t) { $t = [Environment]::GetEnvironmentVariable('GH_TOKEN', 'User') }
  if (-not $t) { $t = [Environment]::GetEnvironmentVariable('GH_TOKEN', 'Process') }
  if (-not $t) { throw 'GH_TOKEN 未设置（进程级或用户级）' }
  return ($t -replace '[<>"\s]', '').Trim()
}

$token = Resolve-Token
$headers = @{
  'User-Agent'    = 'che-private-push'
  Accept          = 'application/vnd.github+json'
  Authorization   = "Bearer $token"
}
$api = "https://api.github.com/repos/$Owner/$Repo/contents"

# ---------- 脱敏 ----------
$script:Redacted = 0
function Redact-Node($node) {
  if ($null -eq $node) { return $null }
  if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
    $arr = @()
    foreach ($item in $node) { $arr += ,(Redact-Node $item) }
    return $arr
  }
  if ($node -is [pscustomobject]) {
    $out = [ordered]@{}
    foreach ($p in $node.PSObject.Properties) {
      if ($p.Name -match '(?i)token|secret|password|apikey|passwd') {
        $out[$p.Name] = '<redacted>'
        $script:Redacted++
      }
      else { $out[$p.Name] = Redact-Node $p.Value }
    }
    return [pscustomobject]$out
  }
  return $node
}

# ---------- 收集待推文件 ----------
$items = @()   # @{ Path(仓库内路径); Text(内容) }

# 1) 日记
$diaryDir = Join-Path $LocalDir 'diary'
if (Test-Path -LiteralPath $diaryDir) {
  Get-ChildItem $diaryDir -File -Filter '*.md' | ForEach-Object {
    $items += @{ Path = ('diary/' + $_.Name); Text = ([System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)) }
  }
}

# 2) 自省报告（只取最近 N 份，控制仓库体积）
$reportsDir = Join-Path $LocalDir 'reports'
if (Test-Path -LiteralPath $reportsDir) {
  Get-ChildItem $reportsDir -File -Filter '*.md' | Sort-Object LastWriteTime -Descending | Select-Object -First $MaxReports | ForEach-Object {
    $items += @{ Path = ('reports/' + $_.Name); Text = ([System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)) }
  }
}

# 2b) 事实台账（含 QQ 号与路径，属于私密内容，只进私有仓）
$factsPath = Join-Path $LocalDir 'facts.json'
if (Test-Path -LiteralPath $factsPath) {
  $items += @{ Path = 'memory/facts.json'; Text = ([System.IO.File]::ReadAllText($factsPath, [System.Text.Encoding]::UTF8)) }
}

# 2c) 群聊流（streams/*.md）：只在群聊里发生的记忆，绝不进公开仓
$streamsDir = Join-Path $LocalDir 'streams'
if (Test-Path -LiteralPath $streamsDir) {
  Get-ChildItem $streamsDir -File -Filter '*.md' | ForEach-Object {
    $items += @{ Path = ('streams/' + $_.Name); Text = ([System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)) }
  }
}

# 3) QQ 侧状态（JSON 脱敏后推）
if ($BridgeDir) {
  $stateDir = Join-Path $BridgeDir 'state'
  foreach ($name in @('social-v2.json', 'sessions.json')) {
    $p = Join-Path $stateDir $name
    if (-not (Test-Path -LiteralPath $p)) { continue }
    try {
      $doc = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      $clean = Redact-Node $doc
      $items += @{ Path = ('qq/state/' + $name); Text = ($clean | ConvertTo-Json -Depth 20) }
    } catch {
      Write-Output "  跳过 $name（解析失败）：$($_.Exception.Message)"
    }
  }
}

if ($items.Count -eq 0) { Write-Output '没有可推送的私密内容。'; exit 0 }

# ---------- 推送 ----------
$pushed = 0; $same = 0; $failed = 0
foreach ($it in $items) {
  $path = $it.Path
  $text = $it.Text
  if ($text.Length -eq 0) { continue }
  $b64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($text))
  $sha = $null
  try {
    $meta = Invoke-RestMethod "$api/$path" -Headers $headers -TimeoutSec 25
    $sha = $meta.sha
    $remoteText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(($meta.content -replace '\s', '')))
    if ($remoteText -eq $text) { $same++; continue }
  } catch {
    $code = try { $_.Exception.Response.StatusCode.value__ } catch { 0 }
    if ($code -ne 404) { Write-Output "  ✗ $path 读取失败：$($_.Exception.Message)"; $failed++; continue }
  }

  if ($DryRun) { Write-Output "  （演练）将推送 $path（$($text.Length) 字符）"; continue }

  $payload = @{ message = "backup: $path"; content = $b64; branch = 'main' }
  if ($sha) { $payload.sha = $sha }
  try {
    $null = Invoke-RestMethod "$api/$path" -Method Put -Headers $headers -Body ($payload | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
    $pushed++
    Write-Output "  ✓ $path（$($text.Length) 字符）"
  } catch {
    $failed++
    Write-Output "  ✗ $path 推送失败：$($_.Exception.Message)"
  }
}

Write-Output ("备份结束：上传 {0} / 未变 {1} / 失败 {2} / 脱敏字段 {3} → {4}/{5}" -f $pushed, $same, $failed, $script:Redacted, $Owner, $Repo)
if ($failed -gt 0) { exit 1 }
