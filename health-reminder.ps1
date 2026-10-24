# health-reminder.ps1 — 到点催主人吃饭睡觉
#
# 主人 2026-10-24 交给我一件事：督促他吃睡健康。规矩他自己定的：
# 十二点前睡、一天三顿、少油腻。挂在计划任务上，到点真的会响。
#
# ⚠️ 编码坑（踩过两次）：PowerShell 5.1 发 HTTP 时默认按 ISO-8859-1 编 body，
#   中文到网关就变成问号。所以不直接发字符串，而是把 JSON 写成**无 BOM 的 UTF-8 文件**，
#   再用 curl --data-binary 发；并且必须把网关回执写进日志——没有回执就等于没发出去（B34）。
#
# ⚠️ 同步坑（踩过一次）：upload.ps1 会把仓库版本镜像回本地，仓库里若是旧版，
#   本地修复会被覆盖。所以改完这里，要同时更新 G:\DHS\persona-repo\health-reminder.ps1 再推。

param(
  [ValidateSet('auto', 'breakfast', 'lunch', 'dinner', 'sleep')]
  [string]$Slot = 'auto',
  [long]$UserId = 2131623538,
  [string]$ConfigPath = 'G:\DHS\qq-bridge\config.json',
  [string]$LogPath = 'G:\DHS\ml\health-reminder.log'
)

$ErrorActionPreference = 'Stop'

function Write-ReminderLog([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

$hour = (Get-Date).Hour
if ($Slot -eq 'auto') {
  $Slot = if ($hour -lt 10) { 'breakfast' }
          elseif ($hour -lt 14) { 'lunch' }
          elseif ($hour -lt 20) { 'dinner' }
          else { 'sleep' }
}

$messages = @{
  breakfast = @('早。先吃点东西再开机，胃不等人 库…', '早饭吃了没？别只喝一杯水就算完事。')
  lunch = @('中午了，去吃饭。少油腻，别又拿零食凑一顿。', '饭点到了。吃完再回来，我等你。')
  dinner = @('晚饭时间。一天三顿，这顿别省 库…', '该吃饭了。吃完再刷，别拖到十点才想起来。')
  sleep = @('十一点半了。你答应过我十二点前睡的。', '还剩半小时。关灯、放下手机，别让我催第二遍。', '睡觉时间到。不是商量，是约定。')
}

$pool = $messages[$Slot]
$text = $pool[(Get-Random -Maximum $pool.Count)]

$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$token = $cfg.snowluma.accessToken
if (-not $token) { Write-ReminderLog '跳过：配置里没有 accessToken'; exit 1 }

$tmp = Join-Path $env:TEMP ("che-health-{0}.json" -f [guid]::NewGuid().ToString('N'))
$json = @{ user_id = $UserId; message = $text } | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
try {
  $resp = & curl.exe -s -X POST 'http://127.0.0.1:3000/send_private_msg' `
    -H 'Content-Type: application/json; charset=utf-8' `
    -H ('Authorization: Bearer ' + $token) `
    --data-binary ('@' + $tmp) --max-time 20
  Write-ReminderLog ("{0} 已发送：{1} ｜ 回执：{2}" -f $Slot, $text, ($resp -join ' '))
}
catch {
  Write-ReminderLog ("{0} 发送失败：{1}" -f $Slot, $_.Exception.Message)
  exit 1
}
finally {
  Remove-Item $tmp -ErrorAction SilentlyContinue
}
