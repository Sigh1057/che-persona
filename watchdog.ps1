# watchdog.ps1 — 桥接看门狗
#
# 为什么需要它：桥接是这具身体里唯一"崩了不会自己好"的部件。它是个独立 node 进程，
# 没有 systemd、没有 supervisor，开机自启只在登录那一次。它挂掉的表现是**安静**——
# QQ 里没人回话，而日志停在某个时刻，没人会注意到。
#
# 它做四件事（按顺序，前一件不成立就不做后一件）：
#   1. DSH 在不在（19387）—— 不在就跳过，不制造假故障
#   2. SnowLuma 在不在（3000/3001）—— 不在只告警：那是要人扫码的东西，本脚本不代启
#   3. 桥接进程在不在 —— 不在就用 start-che.ps1 拉起来，等 8 秒复查
#   4. 控制台端口在不在（3100）—— 进程在但端口不在，说明起了一半，记告警
#
# 由计划任务 CheWatchdog 每 5 分钟调用。日志：watchdog.log（保留最近 300 行）。

[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$Quiet,
  [string]$BridgeDir = ''
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)
$log = Join-Path $here 'watchdog.log'

function Write-Log([string]$m, [string]$level = 'info') {
  $line = ('[{0}] [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $level, $m)
  [System.IO.File]::AppendAllText($log, $line + "`n", $utf8)
  if (-not $Quiet) { Write-Host $line }
}

function Test-Port([int]$port) {
  $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
  return [bool]$c
}

function Get-BridgeProcess {
  return @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'bridge\.js' })
}

if (-not $BridgeDir) {
  foreach ($c in @('G:\DHS\qq-bridge', 'D:\qq-bridge', (Join-Path $env:USERPROFILE 'qq-bridge'))) {
    if (Test-Path -LiteralPath (Join-Path $c 'src\bridge.js')) { $BridgeDir = $c; break }
  }
}
if (-not $BridgeDir) { Write-Log '找不到 qq-bridge 目录，跳过检查' 'warn'; exit 0 }

# 1) DSH
if (-not (Test-Port 19387)) {
  Write-Log 'DSH 未运行（19387 未监听），本轮跳过——不是桥接的故障'
  exit 0
}

# 2) SnowLuma
$snowOk = (Test-Port 3000) -and (Test-Port 3001)
if (-not $snowOk) {
  Write-Log 'SnowLuma 未运行（3000/3001 至少一个未监听）：需要人工启动并扫码，看门狗不代启' 'warn'
}

# 3) 桥接进程
$procs = @(Get-BridgeProcess)
if ($procs.Count -gt 0) {
  $pids = (($procs | ForEach-Object { $_.ProcessId }) -join ',')
  Write-Log ('桥接在运行：PID ' + $pids)
}
else {
  if (-not $snowOk) {
    Write-Log '桥接未运行，且 SnowLuma 也不在——拉起也没用，本轮不拉' 'warn'
    exit 0
  }
  if ($DryRun) {
    Write-Log '（演练）桥接未运行，本应执行 start-che.ps1' 'warn'
    exit 0
  }
  Write-Log '桥接未运行，正在拉起…' 'warn'
  $start = Join-Path $BridgeDir 'start-che.ps1'
  if (-not (Test-Path -LiteralPath $start)) { Write-Log ('找不到启动脚本：' + $start) 'error'; exit 2 }
  Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $start) -WindowStyle Hidden
  Start-Sleep -Seconds 8
  $procs2 = @(Get-BridgeProcess)
  if ($procs2.Count -gt 0) {
    Write-Log ('已拉起：PID ' + (($procs2 | ForEach-Object { $_.ProcessId }) -join ',')) 'info'
  }
  else {
    Write-Log '拉起失败：8 秒后仍无 bridge.js 进程（看 state\bridge.log 的报错）' 'error'
    exit 2
  }
}

# 4) 控制台端口
if (-not (Test-Port 3100)) {
  Write-Log '控制台 3100 未监听：进程在但端口没起来，可能启动中途失败' 'warn'
}

# 日志轮转
try {
  $all = Get-Content -LiteralPath $log -Encoding UTF8
  if ($all.Count -gt 300) { Set-Content -LiteralPath $log -Value ($all | Select-Object -Last 300) -Encoding UTF8 }
} catch { }

if (-not $DryRun) { Write-Log '检查完成：健康' }
exit 0
