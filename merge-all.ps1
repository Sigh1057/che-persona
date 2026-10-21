# merge-all.ps1 — 一次跑完整条归并链
#
# 顺序固定：
#   1) people-merge.ps1  读 qq-bridge 的 social-v2.json，把打了 [长期] 的印象搬进 people/
#   2) memory-merge.ps1  把这一批压成一条记忆条目，交 memory-push -LocalOnly 入档
#   3) 入档后由每小时的心跳（CheHeartbeat）推到 GitHub
#
# 由计划任务 ChePeopleMerge 每 30 分钟调用。
[CmdletBinding()]
param(
  [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot
$log = Join-Path $dir 'merge.log'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Log([string]$m) {
  $line = ('[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m)
  [System.IO.File]::AppendAllText($log, $line + "`n", $utf8)
}

$common = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File')
$extra = @()
if ($DryRun) { $extra += '-DryRun' }

$pm = Join-Path $dir 'people-merge.ps1'
$mm = Join-Path $dir 'memory-merge.ps1'
$pp = Join-Path $dir 'people-push.ps1'

Write-Log '── 开始归并 ──'
# 注意：-File 后面必须紧跟脚本路径，额外开关要放在路径之后。
$out1 = & powershell.exe @common $pm @extra 2>&1
$c1 = $LASTEXITCODE
foreach ($l in $out1) { Write-Log ('  [people] ' + $l) }
if ($c1 -ne 0) { Write-Log ("people-merge 失败（$c1），跳过后续"); exit $c1 }

# 账本备份到私有仓库（Sigh1057/che-people）。失败不阻断：本地账本才是主，备份是副本。
if (Test-Path -LiteralPath $pp) {
  $out3 = & powershell.exe @common $pp @extra 2>&1
  $c3 = $LASTEXITCODE
  foreach ($l in $out3) { Write-Log ('  [backup] ' + $l) }
} else { $c3 = 0 }

$out2 = & powershell.exe @common $mm @extra 2>&1
$c2 = $LASTEXITCODE
foreach ($l in $out2) { Write-Log ('  [memory] ' + $l) }
Write-Log ("── 结束（people=$c1 backup=$c3 memory=$c2）──")
exit $c2
