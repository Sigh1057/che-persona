# context-sync.ps1 — 把"正在聊的上下文"同步到私有仓库
#
# 为什么需要它：DSH 的会话上下文只存在本机 ~/.dsh/sessions 下，换机器就断。
# MEMORY.md 记的是"发生过什么"（摘要），这个脚本记的是"当时怎么说的"（原文）。
#
# 规矩：
#   · 只推私有仓库，且先验证仓库是 private，否则拒绝。
#   · 不打印文件内容，只打印大小与哈希。
#   · 会话原文可能含临时令牌与私人对话——**永远不进公开仓库**。
#
# 用法：
#   .\context-sync.ps1 -Owner Sigh1057 -Repo che-private
#   .\context-sync.ps1 -Owner Sigh1057 -Repo che-private -SessionId session-c3950cec-...

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Owner,
  [Parameter(Mandatory = $true)][string]$Repo,
  [string]$SessionId = '',
  [string]$ApiBase = 'https://api.github.com',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Resolve-Token {
  foreach ($c in @($env:GH_TOKEN, [Environment]::GetEnvironmentVariable('GH_TOKEN', 'User'))) {
    if ([string]::IsNullOrWhiteSpace($c)) { continue }
    $v = $c.Trim().Trim('<', '>').Trim('"', "'")
    if ($v) { return $v }
  }
  throw '找不到 GH_TOKEN'
}

# 找会话文件：优先指定 id，否则取最近修改的那个。
$sessionsRoot = Join-Path $env:USERPROFILE '.dsh\sessions'
$candidate = $null
if ($SessionId) {
  $candidate = Get-ChildItem $sessionsRoot -Recurse -Filter 'session.v4.jsonl.zstd' -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -eq $SessionId } | Select-Object -First 1
}
if (-not $candidate) {
  $candidate = Get-ChildItem $sessionsRoot -Recurse -Filter 'session.v4.jsonl.zstd' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (-not $candidate) { throw "找不到任何会话文件（$sessionsRoot）" }

$sid = $candidate.Directory.Name
$bytes = [System.IO.File]::ReadAllBytes($candidate.FullName)
$sha = ([BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', '').ToLower()
$stamp = (Get-Date).ToString('yyyy-MM-dd-HHmm')
$name = "context/session-$sid-$stamp.jsonl.zstd"

# 清单：换机时先读它，知道有哪些快照、哪一份是最后的。
$manifestPath = Join-Path $env:TEMP 'context-manifest.json'
$manifest = @{
  exportedAt = (Get-Date).ToString('o')
  sessionId  = $sid
  file       = $name
  bytes      = $bytes.Length
  sha256     = $sha
  note       = '会话原文快照。含真实对话与临时令牌，仅存私有库。'
} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($manifestPath, $manifest, $utf8)

Write-Output ("会话: {0}" -f $sid)
Write-Output ("大小: {0:N1} MB   哈希: {1}" -f ($bytes.Length / 1MB), $sha.Substring(0, 16))
if ($DryRun) { Write-Output '（演练模式，未上传）'; return }

$token = Resolve-Token
$headers = @{
  Authorization          = "Bearer $token"
  Accept                 = 'application/vnd.github+json'
  'User-Agent'           = 'dsh-context'
  'X-GitHub-Api-Version' = '2022-11-28'
}

# 仓库必须存在且是 private
try {
  $repoInfo = Invoke-RestMethod "$ApiBase/repos/$Owner/$Repo" -Headers $headers -TimeoutSec 30
  if (-not $repoInfo.private) { throw "仓库 $Owner/$Repo 不是私有的，拒绝写入会话原文" }
  Write-Output "私有仓库确认：$Owner/$Repo"
} catch {
  $status = try { $_.Exception.Response.StatusCode.value__ } catch { 0 }
  if ($status -eq 404) {
    $body = @{ name = $Repo; private = $true; description = '私有：日记/汇报/会话快照'; auto_init = $true } | ConvertTo-Json
    $null = Invoke-RestMethod -Method Post "$ApiBase/user/repos" -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 30
    Write-Output "已创建私有仓库：$Owner/$Repo"
    Start-Sleep -Seconds 2
  } else { throw }
}

function Put-File([string]$relPath, [byte[]]$data) {
  $uri = "$ApiBase/repos/$Owner/$Repo/contents/$relPath"
  $shaExisting = $null
  try { $shaExisting = (Invoke-RestMethod $uri -Headers $headers -TimeoutSec 30).sha } catch { }
  $payload = @{ message = "context: $relPath"; content = [Convert]::ToBase64String($data) }
  if ($shaExisting) { $payload.sha = $shaExisting }
  $r = $null
  for ($i = 1; $i -le 3 -and -not $r; $i++) {
    try {
      $r = Invoke-RestMethod -Method Put $uri -Headers $headers -Body ($payload | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 180
    } catch {
      if ($i -eq 3) { throw }
      Start-Sleep -Seconds (2 * $i)
    }
  }
  Write-Output ("  {0,-60} {1,9:N0} 字节 → {2}" -f $relPath, $data.Length, $r.commit.sha.Substring(0, 8))
}

Put-File $name $bytes
Put-File 'context/MANIFEST.json' ([System.IO.File]::ReadAllBytes($manifestPath))
Write-Output "完成：会话快照已进私有库 $Owner/$Repo（内容未打印）"
