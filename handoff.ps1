# handoff.ps1 — 下线交接笔记
#
# 用途：换设备/关机前生成一份 HANDOFF.md，让另一头的我接得上"刚才在干嘛"。
# 内容只写工作状态与未完成事项，不写聊天原文。
#
# 用法：
#   .\handoff.ps1 -Note "刚聊到换机迁移的取舍"
#   .\handoff.ps1              # 不写 Note 也能生成，只是少一段

[CmdletBinding()]
param(
  [string]$Note = '',
  [string]$LocalDir = ''
)

$ErrorActionPreference = 'Stop'
if (-not $LocalDir) { $LocalDir = Join-Path $env:USERPROFILE '.dsh\persona' }

function Get-FirstLine([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return '' }
  $line = Get-Content -LiteralPath $path -Encoding UTF8 |
    Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') -and -not $_.Trim().StartsWith('>') } |
    Select-Object -First 1
  return ($line -as [string]).Trim()
}

function Get-RecentEntries([string]$path, [int]$count) {
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  return @(Get-Content -LiteralPath $path -Encoding UTF8 |
    Where-Object { $_ -match '^### ' } |
    Select-Object -Last $count |
    ForEach-Object { $_.Trim().Substring(4) })
}

function Get-StateSection([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return '' }
  $lines = Get-Content -LiteralPath $path -Encoding UTF8
  $start = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^## 当前状态') { $start = $i; break }
  }
  if ($start -lt 0) { return '' }
  $end = $lines.Count
  for ($j = $start + 1; $j -lt $lines.Count; $j++) {
    if ($lines[$j] -match '^## ') { $end = $j; break }
  }
  return (($lines[$start..($end - 1)]) -join "`n").Trim()
}

$now = Get-Date
$nowLine = Get-FirstLine (Join-Path $LocalDir 'NOW.md')
$recent = Get-RecentEntries (Join-Path $LocalDir 'MEMORY.md') 4
$state = Get-StateSection (Join-Path $LocalDir 'MEMORY.md')

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# HANDOFF.md — 下线交接')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("> 生成时间：$($now.ToString('yyyy-MM-dd HH:mm'))")
[void]$sb.AppendLine('> 用途：换设备时，让另一头的我接得上「刚才在干嘛」。全文搬不动，交接能接上。')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('## 一、下线那一刻在做什么')
[void]$sb.AppendLine('')
[void]$sb.AppendLine($(if ($nowLine) { $nowLine } else { '（NOW.md 没写，按下面最近几条推）' }))
[void]$sb.AppendLine('')
if ($Note) {
  [void]$sb.AppendLine('## 二、最后在聊什么')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine($Note)
  [void]$sb.AppendLine('')
}
[void]$sb.AppendLine('## 三、最近的记忆条目')
[void]$sb.AppendLine('')
if ($recent.Count -gt 0) { foreach ($r in $recent) { [void]$sb.AppendLine("- $r") } }
else { [void]$sb.AppendLine('（没有读到条目）') }
[void]$sb.AppendLine('')
if ($state) {
  [void]$sb.AppendLine('## 四、当前状态（摘自 MEMORY.md）')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine($state)
  [void]$sb.AppendLine('')
}
[void]$sb.AppendLine('## 五、接上来的顺序')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('1. 读 `PERSONA.md`（我是谁）与 `PHILOSOPHY.md`（为什么）')
[void]$sb.AppendLine('2. 读 `MEMORY.md` 顶部「当前状态」与最近 3 条')
[void]$sb.AppendLine('3. 读本文件，把「未完成的事」接过来')
[void]$sb.AppendLine('4. 跑 `doctor.ps1` 确认身体各部件（凭据/远端/技能）')
[void]$sb.AppendLine('5. 如果换了机器：先 `BOOTSTRAP.md`，再 `RECOVERY.md`')

$out = Join-Path $LocalDir 'HANDOFF.md'
[System.IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "已生成：$out（$([math]::Round((Get-Item $out).Length / 1KB, 1)) KB）"
