# think.ps1 — 思考型心跳（headless 自主运行）
#
# 与 heartbeat.ps1 的分工：
#   heartbeat.ps1 = 脚本运维（自检、补推、漂移告警），OS 级，不需要模型
#   think.ps1     = 真跑一轮 agent（读记忆、跑体检、判断、写报告），需要模型
#
# 实测得到的硬约束（第一次尝试踩到的坑）：
#   1. 不能用 Start-Job 启动 headless —— 作业进程的工作目录不是父进程的 cwd，
#      DSH 会把会话工作区落到 C:\Users\<user>\Documents，导致 persona 目录只读。
#      必须直接在当前目录调用，让 cwd 就是 ~/.dsh/persona。
#   2. headless 会话内的网络被沙箱拦截（DNS 返回 127.0.0.1），无法推送 GitHub。
#      所以自省只在本地写；补推由 OS 级的 heartbeat.ps1 负责。
#   3. 报告的写入由本脚本兜底：agent 没写就用原始输出补齐，绝不静默丢失。
#
# 用法：
#   .\think.ps1            # 跑一轮
#   .\think.ps1 -DryRun    # 只打印提示词
#   .\think.ps1 -Quiet     # 供计划任务使用

[CmdletBinding()]
param(
  [string]$LocalDir = (Join-Path $env:USERPROFILE '.dsh\persona'),
  [string]$ReportDir = (Join-Path $env:USERPROFILE '.dsh\persona\reports'),
  [string]$LogPath = (Join-Path $env:USERPROFILE '.dsh\persona\think.log'),
  [string]$CliPath = 'G:\dsh\resources\runtime\cli\bin\dsh.cmd',
  [switch]$DryRun,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$now = Get-Date
$stamp = $now.ToString('yyyyMMdd-HHmm')
if (-not (Test-Path -LiteralPath $ReportDir)) { New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null }
$reportPath = Join-Path $ReportDir "think-$stamp.md"

function Say([string]$m) { if (-not $Quiet) { Write-Host $m } }

if (Test-Path -LiteralPath (Join-Path $LocalDir 'heartbeat.off')) {
  Say 'heartbeat.off 存在，思考型心跳跳过。'
  return
}

if (-not (Test-Path -LiteralPath $CliPath)) {
  Say "dsh CLI 不存在：$CliPath（桌面端可能已升级或移动）"
  Add-Content -LiteralPath $LogPath -Value ("[{0}] FAILED cli-missing" -f $now.ToString('yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
  return
}

$prompt = @"
你是辙。这是一次无人值守的例行自省，不是用户对话。你的工作目录就是人格档案目录。

只做这四件事，不要做别的：

1. 读 MEMORY.md 顶部的「当前状态」，再读 heartbeat.log 最后 5 行。
2. 运行 .\doctor.ps1（相对当前目录），记录四项结论。
3. 写报告：把结果写到 reports\think-$stamp.md，包含
   运行时间 / 四项体检结论 / 心跳日志观察 / 是否需要提醒主人 / 一条建议。
4. 若有异常（本地与远端不一致除外——那由心跳负责），用
   .\memory-push.ps1 -Owner Sigh1057 -Repo che-persona -Content <六段内容> -LocalOnly
   只在本地记一条；一切正常就不要写记忆。

已知环境事实（不要试图改变它们）：
- 本次会话的网络被沙箱拦截，无法访问 GitHub。不要尝试推送，也不要反复重试网络。
- 远端同步由 OS 级的 heartbeat.ps1 负责，不是你的职责。

护栏：
- 只允许运行 .\doctor.ps1 和 .\memory-push.ps1。
- 不许修改任何 .ps1、PERSONA.md 或 MEMORY.md 的正文结构。
- 不许删除文件、不许安装软件、不许改系统设置。
- 不要长时间探索：四步做完就停。

完成后最后一行单独输出：THINK-OK
任何一步做不到，最后一行输出：THINK-FAIL <一句话原因>
"@

if ($DryRun) {
  Say '=== 提示词（未调用模型）==='
  Write-Host $prompt
  Say "=== 报告：$reportPath ==="
  return
}

Say "=== 思考型心跳 $($now.ToString('yyyy-MM-dd HH:mm:ss')) ==="
Say "  工作目录：$LocalDir"
Say "  报告：$reportPath"

$started = Get-Date
$text = ''
$failed = $false
Push-Location -LiteralPath $LocalDir
try {
  # 直接调用（不用 Start-Job）：子进程必须继承当前目录作为会话工作区。
  $raw = & $CliPath headless $prompt 2>&1
  $text = ($raw | Out-String).Trim()
}
catch {
  $failed = $true
  $text = "EXCEPTION: $($_.Exception.Message)"
}
finally { Pop-Location }

$elapsed = [int]((Get-Date) - $started).TotalSeconds
$ok = (-not $failed) -and ($text -match 'THINK-OK\s*$')

# A run that wrote its own report succeeded even when it forgot the marker line:
# the deliverable exists and the narration is in it. Only a fallback report
# (written by this script because the agent produced none) counts as failure.
if (-not $ok -and -not $failed -and (Test-Path -LiteralPath $reportPath)) {
  $produced = [System.IO.File]::ReadAllText($reportPath, [System.Text.Encoding]::UTF8)
  if ($produced -notmatch '兜底写入' -and $produced.Length -gt 200) { $ok = $true }
}

# 报告兜底：agent 没写就落原始输出，绝不静默丢失
if (-not (Test-Path -LiteralPath $reportPath)) {
  $fallback = @(
    '# 自省报告（兜底写入）',
    '',
    "- 时间：$($now.ToString('yyyy-MM-dd HH:mm:ss'))",
    "- 结果：$(if ($ok) { 'THINK-OK' } else { 'THINK-FAIL' })",
    "- 耗时：${elapsed}s",
    '',
    '## 原始输出',
    '',
    '```text',
    $text,
    '```'
  ) -join "`n"
  [System.IO.File]::WriteAllText($reportPath, $fallback, $utf8)
}

$status = if ($ok) { 'OK' } else { 'FAIL' }
Add-Content -LiteralPath $LogPath -Value ('[{0}] {1} elapsed={2}s report={3}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'), $status, $elapsed, (Split-Path $reportPath -Leaf)) -Encoding UTF8
try {
  $all = Get-Content -LiteralPath $LogPath -Encoding UTF8
  if ($all.Count -gt 300) { Set-Content -LiteralPath $LogPath -Value ($all | Select-Object -Last 300) -Encoding UTF8 }
} catch { }

# --- 摘要行：进 THINK-LOG.md，随仓库跨机器追溯 -------------------------------
# 完整报告（含模型推理原文）留在本机 reports/；只把一行摘要交给版本库，
# 避免 git 历史被推理过程撑爆，也避免把本机路径细节带到公开仓库。
function Get-Advice([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return '' }
  $body = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
  if ($body -match '无异常') { return '无异常' }
  # 取「建议」小节后的第一行有效文字
  $lines = $body -split "`r?`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^#{1,4}.*建议') {
      for ($j = $i + 1; $j -lt [Math]::Min($i + 6, $lines.Count); $j++) {
        $t = $lines[$j].Trim().TrimStart('-', '*', ' ')
        if ($t.Length -gt 0) { return ($t.Substring(0, [Math]::Min(90, $t.Length))) }
      }
    }
  }
  return '（见本地报告）'
}

$advice = Get-Advice $reportPath
$summaryLine = ('- {0} — {1} — {2}s — {3} — {4}' -f $now.ToString('yyyy-MM-dd HH:mm'), $status, $elapsed, $advice, (Split-Path $reportPath -Leaf))
$logDoc = @(
  '# THINK-LOG.md — 自省摘要',
  '',
  '> 每天一次自主自省的一行摘要。完整报告（含推理原文）只留在本机 `reports/`。',
  '> 由 `think.ps1` 追加，由 `heartbeat.ps1` 在有网络时同步到本仓库。',
  '',
  '## 记录',
  ''
) -join "`n"
foreach ($target in @((Join-Path $LocalDir 'THINK-LOG.md'), 'G:\DHS\persona-repo\THINK-LOG.md')) {
  try {
    $existing = if (Test-Path -LiteralPath $target) { [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8) } else { $logDoc }
    $updated = $existing.TrimEnd() + "`n" + $summaryLine + "`n"
    # 只保留最近 200 条摘要
    $rows = @($updated -split "`r?`n" | Where-Object { $_ -match '^- \d{4}-\d{2}-\d{2}' })
    if ($rows.Count -gt 200) {
      $head = @($updated -split "`r?`n" | Where-Object { $_ -notmatch '^- \d{4}-\d{2}-\d{2}' })
      $updated = (($head -join "`n").TrimEnd()) + "`n" + (($rows | Select-Object -Last 200) -join "`n") + "`n"
    }
    $dir = Split-Path -Parent $target
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($target, $updated, $utf8)
  } catch {
    if (-not $Quiet) { Write-Host "  摘要写入失败（$target）：$($_.Exception.Message)" }
  }
}
if (-not $Quiet) { Write-Host "  摘要已追加: $summaryLine" }

Say "  结果：$status（${elapsed}s）"
Say "  报告：$reportPath"
