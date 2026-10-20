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
  # 记忆流：main = 主档案（MEMORY.md，会推公开仓）；group 等 = streams/<流>.md，
  # 只留本地并由 private-push 备份到私有仓，永不进公开仓。
  [string]$Stream = 'main',
  # Replaces the "## 当前状态" section body before writing. The header claims
  # this section is overwritten on every push, so leaving it unset kept the
  # status frozen at an old date.
  [string]$State = '',
  # Unattended mode for callers that cannot see console output (heartbeat,
  # scheduled tasks). It suppresses the success narration but NEVER hides an
  # error: failures still write to stderr and set $LASTEXITCODE-compatible state.
  [switch]$Unattended
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$anchor = '## 历史条目'

# Unattended mode only silences the success narration below; every Write-Warning
# and throw path stays visible so a caller can detect failure. A previous
# design shadowed Write-Host wholesale and swallowed a push failure.
$narration = -not $Unattended
function Narrate([string]$message, [string]$color = 'Gray') {
  if ($narration) { Write-Host $message -ForegroundColor $color }
  else { Write-Verbose $message }
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

# Replaces the body of the "## 当前状态" section (between its heading line and
# the next standalone '---'), which the header claims is overwritten on every
# push. Before this existed the section silently went stale — the first
# unattended self-check caught it.
function Set-CurrentState([string]$Base, [string]$StateText) {
  if ([string]::IsNullOrWhiteSpace($Base) -or [string]::IsNullOrWhiteSpace($StateText)) { return $Base }
  $pattern = '(?ms)^(##\s*当前状态[^\r\n]*\r?\n)(.*?)(^---\s*$)'
  if (-not [regex]::IsMatch($Base, $pattern)) { return $Base }
  $body = $StateText.Trim()
  return [regex]::Replace($Base, $pattern, {
      param($m)
      $m.Groups[1].Value + "`n" + $body + "`n`n" + $m.Groups[3].Value
    }, 1)
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

# 群聊流：写进 streams/group.md，只留本地（由 private-push 备份到私有仓），
# 绝不推公开仓——群聊里是别人说的话，不该进公开档案。
if ($Stream -ne 'main') {
  $streamPath = Join-Path $LocalDir ("streams\" + $Stream + '.md')
  $streamDir = Split-Path -Parent $streamPath
  if (-not (Test-Path -LiteralPath $streamDir)) { New-Item -ItemType Directory -Force -Path $streamDir | Out-Null }
  $streamBase = Read-TextFile $streamPath
  if ([string]::IsNullOrWhiteSpace($streamBase)) {
    $streamBase = "# 群聊流（stream: $Stream）`n`n> 只在群聊里发生的记忆。默认不进主档案检索；由 private-push 备份到私有仓。`n`n## 记录`n"
  }
  $streamUpdated = Add-Entry $streamBase $body
  Write-TextFile $streamPath $streamUpdated
  Narrate (("已写入群聊流：{0}（{1} 字符）" -f $streamPath, $streamUpdated.Length)) 'Green'
  Narrate '群聊流不推公开仓库（只进本地与私有备份）。' 'Yellow'
  exit 0
}

# --- 2) LOCAL FIRST (never lose a memory to a network fault) -----------------
$localBase = Read-TextFile $localMemory
if ($null -eq $localBase) {
  $localBase = Read-TextFile $seedPath
  if ($null -ne $localBase) { Narrate "本地镜像无 MEMORY.md，使用仓库种子：$($localBase.Length) 字符" }
}
$localUpdated = Add-Entry $localBase $body
if (-not [string]::IsNullOrWhiteSpace($State)) { $localUpdated = Set-CurrentState $localUpdated $State }
Write-TextFile $localMemory $localUpdated
Narrate (("本地已写入：{0}（{1} 字符）" -f $localMemory, $localUpdated.Length)) 'Green'

if ($LocalOnly) {
  Narrate ''
  Narrate ("已记录（仅本地）：$subject") 'Yellow'
  Narrate '本条未推送到公开仓库（-LocalOnly）。'
  Narrate "位置：$localMemory"
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
    Narrate "已创建仓库 https://github.com/$Owner/$Repo" 'Green'
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
  Narrate "远端 MEMORY.md：$($remoteText.Length) 字符"
}
catch {
  if ($_.Exception.Data['Status'] -eq 404) { Narrate '远端尚无 MEMORY.md，将首次创建。' }
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
# The state section is applied to whatever document actually gets pushed, so a
# merge against a longer remote copy cannot silently drop the refresh.
if (-not [string]::IsNullOrWhiteSpace($State)) { $pushText = Set-CurrentState $pushText $State }

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

Narrate ''
Narrate "已推送：$subject" 'Green'
Narrate "提交：$($result.commit.sha)"
Narrate "地址：https://github.com/$Owner/$Repo/blob/$Branch/MEMORY.md"
Narrate "本地：$localMemory"
Narrate ''
Narrate '两处都已写入。token 保留在环境变量中，下次仍可用。' 'Yellow'
