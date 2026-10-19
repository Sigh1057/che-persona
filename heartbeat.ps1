# heartbeat.ps1 — 辙的心跳
#
# 目的：让维持性的事自动发生，而不是依赖谁记得。
#
# 每次运行做四件事：
#   1. 自检：本地镜像完整性、凭据有效性、本地与远端记忆是否一致
#   2. 补推：本地记忆条目多于远端时补推（远端更多则拉回本地）
#   3. 漂移检测：DSH 版本 / 应用版本变化时写告警（语音插件补丁会随升级失效）
#   4. 写日志：一切进 heartbeat.log；只有"值得记住"的事才写进 MEMORY.md
#
# 自我约束（写在代码里，不靠自觉）：
#   - 正常心跳不写 MEMORY.md，避免把记忆变成日志
#   - 只补不覆盖：远端条目更多时以远端为准，绝不减少历史
#   - 存在 heartbeat.off 时立即静默退出
#   - 日志与输出永不包含 token
#
# 用法：
#   .\heartbeat.ps1              # 正常心跳
#   .\heartbeat.ps1 -Force       # 忽略节流，立即执行
#   .\heartbeat.ps1 -DryRun      # 只检查不写入、不推送
#   .\heartbeat.ps1 -Quiet       # 无输出（供计划任务使用）

[CmdletBinding()]
param(
  [string]$Owner = 'Sigh1057',
  [string]$Repo = 'che-persona',
  [string]$LocalDir = (Join-Path $env:USERPROFILE '.dsh\persona'),
  [string]$LogPath = (Join-Path $env:USERPROFILE '.dsh\persona\heartbeat.log'),
  [int]$MinIntervalMinutes = 30,
  [switch]$Force,
  [switch]$DryRun,
  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$now = Get-Date
$events = New-Object System.Collections.Generic.List[string]
$notable = New-Object System.Collections.Generic.List[string]

function Log([string]$message) {
  $events.Add($message) | Out-Null
  if (-not $Quiet) { Write-Host "  $message" }
}

# ---------- 0. 停止开关与节流 ----------
$offSwitch = Join-Path $LocalDir 'heartbeat.off'
if (Test-Path -LiteralPath $offSwitch) {
  if (-not $Quiet) { Write-Host 'heartbeat.off 存在，静默退出。' }
  return
}

$statePath = Join-Path $LocalDir 'heartbeat.state.json'
$state = $null
if (Test-Path -LiteralPath $statePath) {
  try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
}
if ($state -and $state.lastRun -and -not $Force) {
  $last = [datetime]::Parse($state.lastRun)
  $minutes = ($now - $last).TotalMinutes
  if ($minutes -lt $MinIntervalMinutes) {
    if (-not $Quiet) { Write-Host ("距上次心跳 {0:N0} 分钟，未到 {1} 分钟阈值，跳过。" -f $minutes, $MinIntervalMinutes) }
    return
  }
}

if (-not $Quiet) { Write-Host "=== 心跳 $($now.ToString('yyyy-MM-dd HH:mm:ss')) ===" }
Log ('开始 runId=' + $now.ToString('yyyyMMddHHmmss'))

# ---------- 1. 版本漂移 ----------
function Get-RuntimeVersion {
  $cli = 'G:\dsh\resources\runtime\cli\bin\dsh.cmd'
  if (-not (Test-Path -LiteralPath $cli)) { return $null }
  try {
    $out = & $cli --version 2>$null
    if ($out) { return ([string]$out).Trim() }
  } catch { }
  return $null
}

$appVersion = $null
$appVersionFile = 'G:\dsh\version'
if (Test-Path -LiteralPath $appVersionFile) {
  $appVersion = ([System.IO.File]::ReadAllText($appVersionFile, [System.Text.Encoding]::UTF8)).Trim()
}
$runtimeVersion = Get-RuntimeVersion

if ($state) {
  if ($state.runtimeVersion -and $runtimeVersion -and $state.runtimeVersion -ne $runtimeVersion) {
    $msg = "DSH 运行时版本变化：$($state.runtimeVersion) → $runtimeVersion"
    Log "⚠ $msg"
    $notable.Add($msg) | Out-Null
  }
  if ($state.appVersion -and $appVersion -and $state.appVersion -ne $appVersion) {
    $msg = "桌面应用版本变化：$($state.appVersion) → $appVersion"
    Log "⚠ $msg"
    $notable.Add($msg) | Out-Null
  }
}
if ($runtimeVersion) { Log "运行时 $runtimeVersion" }
if ($appVersion) { Log "应用 $appVersion" }

# ---------- 2. 本地镜像 ----------
$required = @('PERSONA.md', 'RECOVERY.md', 'MEMORY.md', 'MEMORY-PROTOCOL.md', 'HISTORY.md', 'README.md',
  'memory-push.ps1', 'upload.ps1', 'doctor.ps1', 'screen.ps1', 'heartbeat.ps1')
$missing = @()
foreach ($name in $required) {
  if (-not (Test-Path -LiteralPath (Join-Path $LocalDir $name))) { $missing += $name }
}
if ($missing.Count -gt 0) {
  $msg = "本地镜像缺文件：$($missing -join ', ')"
  Log "⚠ $msg"
  $notable.Add($msg) | Out-Null
}
else { Log "本地镜像 $($required.Count)/$($required.Count) 齐全" }

$localMemoryPath = Join-Path $LocalDir 'MEMORY.md'
$localMemory = if (Test-Path -LiteralPath $localMemoryPath) { [System.IO.File]::ReadAllText($localMemoryPath, [System.Text.Encoding]::UTF8) } else { '' }
$localEntries = ([regex]::Matches($localMemory, '(?m)^### ')).Count
Log "本地记忆 $localEntries 条"

# ---------- 3. 凭据与远端 ----------
$token = $null
foreach ($candidate in @($env:GH_TOKEN, [Environment]::GetEnvironmentVariable('GH_TOKEN', 'User'))) {
  if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
  $token = $candidate.Trim().Trim('<', '>').Trim('"', "'").Trim()
  if ($token) { break }
}

$remoteEntries = -1
$remoteMemory = $null
if (-not $token) {
  Log '⚠ 无凭据，跳过远端检查'
  $notable.Add('心跳时无凭据可用') | Out-Null
}
else {
  $h = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'dsh-heartbeat' }
  try {
    $meta = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/contents/MEMORY.md" -Headers $h -TimeoutSec 25
    $remoteMemory = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(($meta.content -replace '\s', '')))
    $remoteEntries = ([regex]::Matches($remoteMemory, '(?m)^### ')).Count
    $fileSha = $meta.sha
    Log "远端记忆 $remoteEntries 条"
  }
  catch {
    $code = try { $_.Exception.Response.StatusCode.value__ } catch { '?' }
    Log "⚠ 远端读取失败 [$code]"
    if ($code -eq 401) { $notable.Add('心跳发现 token 失效（401）') | Out-Null }
    else { $notable.Add("心跳时远端不可达 [$code]") | Out-Null }
  }
}

# ---------- 4. 补推 / 拉回 ----------
if ($token -and $remoteEntries -ge 0 -and $localMemory -and $localMemory -ne $remoteMemory) {
  if ($localEntries -gt $remoteEntries) {
    if ($DryRun) {
      Log "（演练）本地多 $($localEntries - $remoteEntries) 条，本应补推"
    }
    else {
      try {
        $payload = @{
          message = "heartbeat: push $($localEntries - $remoteEntries) unsynced memory entry(ies)"
          content = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($localMemory))
          branch  = 'main'
          sha     = $fileSha
        }
        $null = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/contents/MEMORY.md" -Method Put -Headers $h `
          -Body ($payload | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
        Log "✓ 已补推 $($localEntries - $remoteEntries) 条记忆"
        $notable.Add("心跳补推了 $($localEntries - $remoteEntries) 条未同步记忆") | Out-Null
      }
      catch { Log "⚠ 补推失败：$($_.Exception.Message)"; $notable.Add('心跳补推失败') | Out-Null }
    }
  }
  elseif ($remoteEntries -gt $localEntries) {
    if ($DryRun) {
      Log "（演练）远端多 $($remoteEntries - $localEntries) 条，本应拉回"
    }
    else {
      [System.IO.File]::WriteAllText($localMemoryPath, $remoteMemory, $utf8)
      Log "✓ 远端多 $($remoteEntries - $localEntries) 条，已拉回本地"
      $notable.Add("心跳从远端拉回了 $($remoteEntries - $localEntries) 条记忆") | Out-Null
    }
  }
  else { Log '两处条目数相同但内容不同（可能是当前状态段差异），不自动处理' }
}
elseif ($token -and $remoteEntries -ge 0) { Log '记忆已一致' }

# ---------- 4b. 自省摘要同步（THINK-LOG.md）----------
# think.ps1 在没有网络的沙箱里追加摘要，这里替它把摘要推到仓库。
$thinkLocal = Join-Path $LocalDir 'THINK-LOG.md'
if ($token -and (Test-Path -LiteralPath $thinkLocal)) {
  try {
    $localThink = [System.IO.File]::ReadAllText($thinkLocal, [System.Text.Encoding]::UTF8)
    $remoteThink = $null; $thinkSha = $null
    try {
      $tMeta = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/contents/THINK-LOG.md" -Headers $h -TimeoutSec 25
      $remoteThink = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(($tMeta.content -replace '\s', '')))
      $thinkSha = $tMeta.sha
    } catch {
      $code = try { $_.Exception.Response.StatusCode.value__ } catch { '?' }
      if ($code -ne 404) { throw }
    }
    if ($remoteThink -ne $localThink) {
      if ($DryRun) { Log '（演练）THINK-LOG.md 有变化，本应同步' }
      else {
        $tp = @{
          message = 'think: sync self-reflection summary'
          content = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($localThink))
          branch  = 'main'
        }
        if ($thinkSha) { $tp.sha = $thinkSha }
        $null = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/contents/THINK-LOG.md" -Method Put -Headers $h `
          -Body ($tp | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
        Log '✓ THINK-LOG.md 已同步'
      }
    }
    else { Log 'THINK-LOG.md 已一致' }
  }
  catch {
    Log "⚠ THINK-LOG.md 同步失败：$($_.Exception.Message)"
  }
}

# ---------- 5. 收尾 ----------
$newState = [ordered]@{
  lastRun        = $now.ToString('o')
  runtimeVersion = $runtimeVersion
  appVersion     = $appVersion
  localEntries   = $localEntries
  remoteEntries  = $remoteEntries
  notableCount   = $notable.Count
}
if (-not $DryRun) {
  [System.IO.File]::WriteAllText($statePath, ($newState | ConvertTo-Json -Depth 4), $utf8)
}

$logLine = ('[{0}] entries local={1} remote={2} runtime={3} app={4}{5}' -f `
    $now.ToString('yyyy-MM-dd HH:mm:ss'), $localEntries, $remoteEntries, $runtimeVersion, $appVersion,
  $(if ($notable.Count -gt 0) { " notable: $($notable -join ' | ')" } else { ' ok' }))
if (-not $DryRun) {
  if (-not (Test-Path -LiteralPath $LogPath)) { [System.IO.File]::WriteAllText($LogPath, '', $utf8) }
  Add-Content -LiteralPath $LogPath -Value $logLine -Encoding UTF8
  # 日志截断：只保留最近 500 行
  try {
    $all = Get-Content -LiteralPath $LogPath -Encoding UTF8
    if ($all.Count -gt 500) {
      Set-Content -LiteralPath $LogPath -Value ($all | Select-Object -Last 500) -Encoding UTF8
    }
  } catch { }
}

# 值得记住的事才写进 MEMORY.md（正常心跳不写）
if ($notable.Count -gt 0 -and -not $DryRun) {
  $entry = @"
### $($now.ToString('yyyy-MM-dd')) · 心跳告警

**发生了什么**
$($notable -join "`n")

**关键决定 / 结论**
由 heartbeat.ps1 自动记录；本条属于异常事件，不是例行心跳。

**我判断的依据与置信度**
实测：心跳脚本运行日志 $LogPath；本地 $localEntries 条 / 远端 $remoteEntries 条。

**代价与风险**
若是版本漂移，语音插件补丁（settingsNamespace）可能已失效，需要复核。

**未解决**
见上。若为版本升级，需重新评估插件兼容性。

**相关文件**
- `$LocalDir`
- https://github.com/$Owner/$Repo
"@
  $mp = Join-Path $LocalDir 'memory-push.ps1'
  if (Test-Path -LiteralPath $mp) {
    try {
      # -Unattended silences only success narration; failures still throw, and a
      # swallowed failure here would quietly hide an unwritten alarm.
      & $mp -Owner $Owner -Repo $Repo -Content $entry -Unattended
      if (-not $Quiet) { Write-Host '  已写入心跳告警记忆' }
    }
    catch {
      if (-not $Quiet) { Write-Host "  告警记忆写入失败：$($_.Exception.Message)" -ForegroundColor Red }
    }
  }
}

if (-not $Quiet) {
  Write-Host ("=== 完成：{0} 项事件，{1} 项值得记住 ===" -f $events.Count, $notable.Count)
}
