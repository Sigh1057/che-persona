# coo-adapter-guard.ps1 — 适配器看门狗
#
# 为什么需要：Coo 的适配器是普通 node 进程，崩了不会自己回来，
# 而 Coo 那边只会一直转圈，看不出是"我死了"还是"我慢"。
#
# 做法：每 5 分钟检查一次 /health；不通就拉起，并写一行日志。
# 只做这一件事，不碰别的进程。

param(
  [string]$SessionId = 'session-c3950cec-154a-4cb6-9720-83208042a0ed',
  [int]$Port = 8788,
  [string]$AdapterPath = 'G:\DHS\ml\coo-adapter.mjs',
  [string]$LogPath = 'G:\DHS\ml\adapter-guard.log'
)

$ErrorActionPreference = 'Continue'

function Write-GuardLog([string]$message) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message
  Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

$running = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -match 'coo-adapter' })

$healthy = $false
try {
  $r = Invoke-WebRequest "http://127.0.0.1:$Port/health" -TimeoutSec 5 -UseBasicParsing
  $j = $r.Content | ConvertFrom-Json
  if ($j.ok -and $j.consumer) { $healthy = $true }
}
catch { }

if ($healthy) {
  if ($running.Count -eq 0) {
    # 端口通但进程查不到：可能命令行匹配不到，不动它，只记一笔
    Write-GuardLog "health OK 但没匹配到进程（可能命令行不同），跳过"
  }
  exit 0
}

if ($running.Count -gt 0) {
  Write-GuardLog "health 不通但有进程（$($running.Count) 个），重启"
  $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2
}

$env:COO_SESSION = $SessionId
Start-Process -FilePath 'node' `
  -ArgumentList $AdapterPath `
  -WorkingDirectory (Split-Path $AdapterPath) `
  -WindowStyle Hidden `
  -RedirectStandardOutput 'G:\DHS\ml\adapter.out.log' `
  -RedirectStandardError 'G:\DHS\ml\adapter.err.log'

Start-Sleep -Seconds 4
try {
  $r = Invoke-WebRequest "http://127.0.0.1:$Port/health" -TimeoutSec 5 -UseBasicParsing
  Write-GuardLog "已拉起：$($r.StatusCode)"
}
catch {
  Write-GuardLog "拉起失败：$($_.Exception.Message)"
}
