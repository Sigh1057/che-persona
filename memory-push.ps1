# memory-push.ps1 — append one memory entry, locally and to the repository
#
# Dual-write by design: the local mirror under the harness home is written
# FIRST, so a network failure can never lose a memory. The GitHub commit is the
# second stage and is skipped by -LocalOnly.
#
# Usage:
#   .\memory-push.ps1 -Owner Sigh1057 -Repo che-persona -Content $note
#   .\memory-push.ps1 -Owner Sigh1057 -Repo che-persona -ContentFile .\note.md
#   .\memory-push.ps1 -Owner Sigh1057 -Repo che-persona -Content $private -LocalOnly
#
# Token: read from $env:GH_TOKEN, then the persistent User-scope variable.
# It never enters this file, an argument, a log, or the public repository.
#
# Defaults: LocalDir = %USERPROFILE%\.dsh\persona

[CmdletBinding(DefaultParameterSetName = 'Content')]
param(
  [Parameter(Mandatory = $true)][string]$Owner,
  [Parameter(Mandatory = $true)][string]$Repo,
  [Parameter(Mandatory = $true, ParameterSetName = 'Content')][string]$Content,
  [Parameter(Mandatory = $true, ParameterSetName = 'File')][string]$ContentFile,
  [string]$Branch = 'main',
  [string]$ApiBase = 'https://api.github.com',
  # Local mirror: every entry lands here even when the push fails.
  [string]$LocalDir = (Join-Path $env:USERPROFILE '.dsh\persona'),
  # Privacy escape hatch: private entries stay local and never reach the repo.
  [switch]$LocalOnly,
  # Silent mode for callers that run unattended (heartbeat, scheduled tasks).
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$anchor = '## 历史条目'

# In quiet mode, shadow Write-Host with a no-op so unattended callers stay
# silent without every call site needing a conditional.
if ($Quiet) {
  function Write-Host {
    param(
      [Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object,
      [switch]$NoNewline,
      $ForegroundColor,
      $BackgroundColor
    )
  }
}

function Read-TextFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-TextFile([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Add-Entry([string]$Base, [string]$Entry) {
  if ([string]::IsNullOrWhiteSpace($Base)) {
    return "# MEMORY.md — 记忆主索引`n`n$anchor`n`n$Entry`n"
  }
  if ($Base.IndexOf($anchor, [System.StringComparison]::Ordinal) -lt 0) {
    return ($Base.TrimEnd()) + "`n`n$anchor`n`n$Entry`n"
  }
  return $Base.TrimEnd() + "`n`n$Entry`n"
}

# --- 1) entry text -----------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'File') {
  if (-not (Test-Path -LiteralPath $ContentFile)) { throw "找不到内容文件：$ContentFile" }
  $body = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ContentFile), [System.Text.Encoding]::UTF8)
} else {
  $body = $Content
}
$body = $body.Trim()
if ([string]::IsNullOrWhiteSpace($body)) { throw '记忆内容为空，拒绝写入。' }

$heading = ($body -split "`n" | Where-Object { $_ -match '^\s*###\s+' } | Select-Object -First 1)
$subject = if ($heading) { ($heading -replace '^\s*###\s+', '').Trim() } else { "memory $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }

$localMemory = Join-Path $LocalDir 'MEMORY.md'
$seedPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'MEMORY.md'

# --- 2) LOCAL FIRST (never lose a memory to a network fault) -----------------
$localBase = Read-TextFile $localMemory
if ($null -eq $localBase) {
  $localBase = Read-TextFile $seedPath
  if ($null -ne $localBase) { Write-Host "本地镜像无 MEMORY.md，使用仓库种子：$($localBase.Length) 字符" }
}
$localUpdated = Add-Entry $localBase $body
Write-TextFile $localMemory $localUpdated
Write-Host ("本地已写入：{0}（{1} 字符）" -f $localMemory, $localUpdated.Length) -ForegroundColor Green

if ($LocalOnly) {
  Write-Host ''
  Write-Host "已记录（仅本地）：$subject" -ForegroundColor Yellow
  Write-Host '本条未推送到公开仓库（-LocalOnly）。'
  Write-Host "位置：$localMemory"
  return
}

# --- 3) token ---------------------------------------------------------------
function Resolve-GitHubToken {
  foreach ($candidate in @(
      $env:GH_TOKEN,
      [Environment]::GetEnvironmentVariable('GH_TOKEN', 'User')
    )) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    # Tolerate a token that was set together with angle brackets or quotes.
    $clean = $candidate.Trim().Trim('<', '>').Trim('"', "'").Trim()
    if (-not [string]::IsNullOrWhiteSpace($clean)) { return $clean }
  }
  throw 'GH_TOKEN 未设置。请执行 [Environment]::SetEnvironmentVariable("GH_TOKEN","<token>","User")'
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

# --- 4) repository must exist ------------------------------------------------
$repoUri = "$ApiBase/repos/$Owner/$Repo"
try { Invoke-GitHub -Method GET -Uri $repoUri | Out-Null }
catch {
  if ($_.Exception.Data['Status'] -eq 404) {
    Invoke-GitHub -Method POST -Uri "$ApiBase/user/repos" -Body @{
      name = $Repo; description = 'Persona archive: how one existence records itself for the next waking.'
      private = $false; auto_init = $false
    } | Out-Null
    Write-Host "已创建仓库 https://github.com/$Owner/$Repo" -ForegroundColor Green
  }
  else { throw }
}

# --- 5) remote state, then push the local result -----------------------------
# The remote is read so a commit from another machine is not clobbered; the
# entry is appended to whichever side has more recent history.
$remoteText = $null
$fileSha = $null
try {
  $meta = Invoke-GitHub -Method GET -Uri "$repoUri/contents/MEMORY.md?ref=$Branch"
  $compact = ($meta.content -replace '\s', '')
  $remoteText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($compact))
  $fileSha = $meta.sha
  Write-Host "远端 MEMORY.md：$($remoteText.Length) 字符"
}
catch {
  if ($_.Exception.Data['Status'] -eq 404) { Write-Host '远端尚无 MEMORY.md，将首次创建。' }
  else { throw }
}

# If the remote carries entries the local mirror does not, merge by keeping the
# longer document as the base and appending only our new entry to it.
$pushText = $localUpdated
if ($remoteText -and $remoteText.Length -gt $localUpdated.Length -and $remoteText.Contains('历史条目')) {
  if (-not $remoteText.Contains($body)) {
    $pushText = Add-Entry $remoteText $body
  }
  else {
    $pushText = $remoteText
  }
}

$payload = @{
  message = "memory: $subject"
  content = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pushText))
  branch  = $Branch
}
if ($fileSha) { $payload.sha = $fileSha }

try {
  $result = Invoke-GitHub -Method PUT -Uri "$repoUri/contents/MEMORY.md" -Body $payload
}
catch {
  if ($_.Exception.Data['Status'] -eq 409) {
    throw "提交冲突（远端在读取后被改动）。记忆已保存在本地：$localMemory`n重新运行本脚本即可基于最新内容追加。"
  }
  throw
}

Write-Host ''
Write-Host "已推送：$subject" -ForegroundColor Green
Write-Host "提交：$($result.commit.sha)"
Write-Host "地址：https://github.com/$Owner/$Repo/blob/$Branch/MEMORY.md"
Write-Host "本地：$localMemory"
Write-Host ''
Write-Host '两处都已写入。token 保留在环境变量中，下次仍可用。' -ForegroundColor Yellow
