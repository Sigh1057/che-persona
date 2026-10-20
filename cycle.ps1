# cycle.ps1 — 维护周期：角色卡 → 记忆归并 → 索引重建
#
# 为什么合成一个脚本：这三件事有先后依赖——
#   角色卡要用最新的人格与记忆；
#   归并要把 QQ 侧印象写进账本与记忆；
#   索引要在记忆更新之后重建，否则检索面过期。
#
# 由计划任务 CheCycle 每 30 分钟调用。失败不互相阻断，各自记日志。

[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$common = @('-NoProfile','-ExecutionPolicy','Bypass','-File')
$utf8 = New-Object System.Text.UTF8Encoding($false)
$log = Join-Path $here 'cycle.log'

function Write-Log([string]$m) {
  $line = ('[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m)
  [System.IO.File]::AppendAllText($log, $line + "`n", $utf8)
  if (-not $Quiet) { Write-Host $line }
}

Write-Log '── 周期开始 ──'

# 1) 角色卡（人格/记忆变了，QQ 侧下一句话就用新的）
$syncRole = 'G:\DHS\qq-bridge\sync-role.ps1'
if (Test-Path -LiteralPath $syncRole) {
  $o = & $ps @common $syncRole 2>&1
  foreach ($l in $o) { Write-Log ('  [role] ' + $l) }
} else { Write-Log '  [role] 跳过：找不到 sync-role.ps1' }

# 2) 归并链（人物账本 + 内存合并 + 私有备份）
$merge = Join-Path $here 'merge-all.ps1'
if (Test-Path -LiteralPath $merge) {
  $o = & $ps @common $merge 2>&1
  foreach ($l in $o) { Write-Log ('  [merge] ' + $l) }
} else { Write-Log '  [merge] 跳过：找不到 merge-all.ps1' }

# 3) 私密备份（日记 + QQ 状态快照 → 私有仓 che-private；脱敏后推）
$priv = Join-Path $here 'private-push.ps1'
if (Test-Path -LiteralPath $priv) {
  $o = & $ps @common $priv 2>&1
  foreach ($l in $o) { Write-Log ('  [private] ' + $l) }
} else { Write-Log '  [private] 跳过：找不到 private-push.ps1' }

# 4) 索引重建（记忆变了，检索面要跟上）
$index = Join-Path $here 'index.ps1'
if (Test-Path -LiteralPath $index) {
  $o = & $ps @common $index 2>&1
  foreach ($l in $o) { Write-Log ('  [index] ' + $l) }
} else { Write-Log '  [index] 跳过：找不到 index.ps1' }

# 日志轮转
try {
  $all = Get-Content -LiteralPath $log -Encoding UTF8
  if ($all.Count -gt 400) {
    Set-Content -LiteralPath $log -Value ($all | Select-Object -Last 400) -Encoding UTF8
  }
} catch { }

Write-Log '── 周期结束 ──'
