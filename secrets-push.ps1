# secrets-push.ps1 — 把敏感文件推到私有仓库（与公开仓库完全分开）
#
# 用途：凭据、PII、不公开的状态，只进 che-secrets（私有），永不进 che-persona（公开）。
# 规矩：
#   · 只推白名单里的路径，不做目录扫描——避免误推。
#   · 不打印文件内容，只打印文件名、大小、提交哈希。
#   · token 从环境变量读，never 写入仓库（否则等于把钥匙锁在柜子里）。
#
# 用法：
#   $env:GH_TOKEN = "<token>"      # 需要 repo scope
#   .\secrets-push.ps1 -Owner Sigh1057 -Repo che-secrets

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Owner,
  [Parameter(Mandatory = $true)][string]$Repo,
  [string]$Message = "secrets snapshot",
  [string[]]$Files = @(),
  [string]$ApiBase = 'https://api.github.com'
)

$ErrorActionPreference = 'Stop'

# 白名单：只有这些路径会被推。新增敏感文件时把它加进来。
$DefaultFiles = @(
  (Join-Path $env:USERPROFILE '.bili-ai\credentials.json')
)

$paths = if ($Files.Count -gt 0) { $Files } else { $DefaultFiles }

function Resolve-Token {
  foreach ($c in @($env:GH_TOKEN, [Environment]::GetEnvironmentVariable('GH_TOKEN', 'User'))) {
    if ([string]::IsNullOrWhiteSpace($c)) { continue }
    $v = $c.Trim().Trim('<', '>').Trim('"', "'")
    if ($v) { return $v }
  }
  throw '找不到 GH_TOKEN'
}

$token = Resolve-Token
$headers = @{
  Authorization          = "Bearer $token"
  Accept                 = 'application/vnd.github+json'
  'User-Agent'           = 'dsh-secrets'
  'X-GitHub-Api-Version' = '2022-11-28'
}

# 确保仓库存在且是 private
try {
  $repo = Invoke-RestMethod "$ApiBase/repos/$Owner/$Repo" -Headers $headers -TimeoutSec 30
  if (-not $repo.private) { throw "仓库 $Owner/$Repo 不是私有的，拒绝写入" }
  Write-Output "私有仓库确认：$Owner/$Repo"
}
catch {
  $status = try { $_.Exception.Response.StatusCode.value__ } catch { 0 }
  if ($status -eq 404) {
    $body = @{ name = $Repo; private = $true; description = '敏感信息（凭据/PII）；不公开'; auto_init = $true } | ConvertTo-Json
    $null = Invoke-RestMethod -Method Post "$ApiBase/user/repos" -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 30
    Write-Output "已创建私有仓库：$Owner/$Repo"
    Start-Sleep -Seconds 2
  }
  else { throw }
}

$uploaded = 0
foreach ($p in $paths) {
  if (-not (Test-Path -LiteralPath $p)) { Write-Output "  跳过（不存在）：$(Split-Path $p -Leaf)"; continue }
  $name = Split-Path $p -Leaf
  $bytes = [System.IO.File]::ReadAllBytes($p)
  $b64 = [Convert]::ToBase64String($bytes)
  $uri = "$ApiBase/repos/$Owner/$Repo/contents/$name"
  $sha = $null
  try {
    $existing = Invoke-RestMethod $uri -Headers $headers -TimeoutSec 30
    $sha = $existing.sha
  } catch { }
  $payload = @{ message = "$Message · $name"; content = $b64 }
  if ($sha) { $payload.sha = $sha }
  try {
    $r = Invoke-RestMethod -Method Put $uri -Headers $headers -Body ($payload | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60
    Write-Output ("  {0,-22} {1,7} 字节 -> {2}" -f $name, $bytes.Length, $r.commit.sha.Substring(0, 8))
    $uploaded++
  }
  catch {
    Write-Output ("  {0,-22} 失败：{1}" -f $name, $_.Exception.Message)
  }
}

Write-Output "完成：$uploaded 个文件已进私有仓库 $Owner/$Repo（内容未打印）"
