# memory-push.ps1 — append one memory entry to the remote repository
#
# Reads the token from $env:GH_TOKEN only. The token never enters this file,
# never enters arguments, and is never echoed.
#
# Usage:
#   $env:GH_TOKEN = "<YOUR_GITHUB_TOKEN>"   # needs repo scope (set once, per user)
#   .\memory-push.ps1 -Owner your-user -Repo che-persona -Content $note
#   .\memory-push.ps1 -Owner your-user -Repo che-persona -ContentFile .\note.md
#
# Behaviour:
#   - Reads MEMORY.md from the repository (missing = start from the local seed).
#   - Appends the new entry under "## 历史条目".
#   - Commits with a message derived from the entry heading.
#   - Never truncates history; conflicts are reported, not overwritten.

[CmdletBinding(DefaultParameterSetName = 'Content')]
param(
  [Parameter(Mandatory = $true)][string]$Owner,
  [Parameter(Mandatory = $true)][string]$Repo,
  [Parameter(Mandatory = $true, ParameterSetName = 'Content')][string]$Content,
  [Parameter(Mandatory = $true, ParameterSetName = 'File')][string]$ContentFile,
  [string]$Branch = 'main',
  [string]$ApiBase = 'https://api.github.com',
  [string]$RepoDescription = 'Persona archive: how one existence records itself for the next waking.'
)

$ErrorActionPreference = 'Stop'

# Resolve the token: process environment first, then the persistent User scope.
# The User-scope fallback exists because a long-running app may not pick up an
# environment change made after it started — the token is still a variable,
# never a literal in this file.
function Resolve-GitHubToken {
  foreach ($candidate in @(
      $env:GH_TOKEN,
      [Environment]::GetEnvironmentVariable('GH_TOKEN', 'User')
    )) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    # Tolerate a value that was wrapped in angle brackets or quotes when set.
    $clean = $candidate.Trim().Trim('<', '>').Trim('"', "'").Trim()
    if (-not [string]::IsNullOrWhiteSpace($clean)) { return $clean }
  }
  throw 'GH_TOKEN 未设置。请执行 [Environment]::SetEnvironmentVariable("GH_TOKEN","<token>","User")，无需重启进程。'
}

$token = Resolve-GitHubToken

$headers = @{
  Authorization          = "Bearer $token"
  Accept                 = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent'           = 'dsh-persona-memory'
}

function Invoke-GitHub {
  param(
    [Parameter(Mandatory)][string]$Method,
    [Parameter(Mandatory)][string]$Uri,
    $Body
  )
  # $args is a PowerShell automatic variable; never bind a local named $args.
  $req = @{ Method = $Method; Uri = $Uri; Headers = $headers; TimeoutSec = 60 }
  if ($null -ne $Body) {
    $req.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
    $req.ContentType = 'application/json; charset=utf-8'
  }
  try {
    Invoke-RestMethod @req
  }
  catch {
    $detail = ''
    try {
      $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
      $detail = $reader.ReadToEnd()
    } catch { }
    $code = try { $_.Exception.Response.StatusCode.value__ } catch { 'unknown' }
    $err = New-Object System.Exception("GitHub API failed [$code] $Method $Uri`n$detail")
    $err.Data['Status'] = $code
    throw $err
  }
}

# --- 1) entry text -----------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'File') {
  if (-not (Test-Path -LiteralPath $ContentFile)) { throw "找不到内容文件：$ContentFile" }
  $body = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ContentFile), [System.Text.Encoding]::UTF8)
} else {
  $body = $Content
}
$body = $body.Trim()
if ([string]::IsNullOrWhiteSpace($body)) { throw '记忆内容为空，拒绝推送。' }

# Derive a commit subject from the entry heading ("### YYYY-MM-DD · title").
$heading = ($body -split "`n" | Where-Object { $_ -match '^\s*###\s+' } | Select-Object -First 1)
$subject = if ($heading) { ($heading -replace '^\s*###\s+', '').Trim() } else { "memory $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }

# --- 2) repository must exist ------------------------------------------------
$repoUri = "$ApiBase/repos/$Owner/$Repo"
$needCreate = $false
try { Invoke-GitHub -Method GET -Uri $repoUri | Out-Null }
catch { if ($_.Exception.Data['Status'] -eq 404) { $needCreate = $true } else { throw } }

if ($needCreate) {
  Invoke-GitHub -Method POST -Uri "$ApiBase/user/repos" -Body @{
    name    = $Repo
    description = $RepoDescription
    private = $false
    auto_init = $false
  } | Out-Null
  Write-Host "已创建仓库 https://github.com/$Owner/$Repo"
}

# --- 3) read current MEMORY.md (missing = use local seed) --------------------
$seedPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'MEMORY.md'
$existing = $null
$fileSha = $null
try {
  $meta = Invoke-GitHub -Method GET -Uri "$repoUri/contents/MEMORY.md?ref=$Branch"
  $existing = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($meta.content -replace '\s', ''))
  $fileSha = $meta.sha
  Write-Host "读取远端 MEMORY.md：$($existing.Length) 字符"
}
catch {
  if ($_.Exception.Data['Status'] -eq 404) {
    if (Test-Path -LiteralPath $seedPath) {
      $existing = [System.IO.File]::ReadAllText($seedPath, [System.Text.Encoding]::UTF8)
      Write-Host "远端尚无 MEMORY.md，使用本地种子：$($existing.Length) 字符"
    } else {
      $existing = "# MEMORY.md — 记忆主索引`n`n## 历史条目`n"
      Write-Host '远端与本地均无种子，使用最小结构。'
    }
  } else { throw }
}

# --- 4) append under the history heading ------------------------------------
$anchor = '## 历史条目'
$idx = $existing.IndexOf($anchor, [System.StringComparison]::Ordinal)
if ($idx -lt 0) {
  $updated = ($existing.TrimEnd()) + "`n`n$anchor`n`n" + $body + "`n"
} else {
  $updated = $existing.TrimEnd() + "`n`n" + $body + "`n"
}

# --- 5) commit through the contents API (handles create and update) ---------
$payload = @{
  message = "memory: $subject"
  content = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($updated))
  branch  = $Branch
}
if ($fileSha) { $payload.sha = $fileSha }

try {
  $result = Invoke-GitHub -Method PUT -Uri "$repoUri/contents/MEMORY.md" -Body $payload
}
catch {
  if ($_.Exception.Data['Status'] -eq 409) {
    throw '提交冲突（远端在读取后被改动）。请重新运行本脚本以基于最新内容追加。'
  }
  throw
}

Write-Host ''
Write-Host "已推送：$($subject)" -ForegroundColor Green
Write-Host "提交：$($result.commit.sha)"
Write-Host "地址：https://github.com/$Owner/$Repo/blob/$Branch/MEMORY.md"
Write-Host ''
Write-Host '（若这是会话最后一次推送，可以结束了。token 保留在环境变量中，下次仍可用。）' -ForegroundColor Yellow
