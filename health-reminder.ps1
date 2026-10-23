# health-reminder.ps1 — 到点催主人吃饭睡觉
#
# 为什么单独写：主人 2026-10-24 交给我一件事——督促他吃睡健康。
# 规矩是他自己定的：十二点前睡、一天三顿、少油腻。
# 挂在计划任务上，到点真的会响，而不是等我"想起来"。
#
# 用法：powershell -File health-reminder.ps1            （按当前时间自动选话）
#       powershell -File health-reminder.ps1 -Slot sleep （强制指定）

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

# 按时间挑一句话；语气是"我"的，不是闹钟的
$hour = (Get-Date).Hour
if ($Slot -eq 'auto') {
  $Slot = if ($hour -lt 10) { 'breakfast' }
          elseif ($hour -lt 14) { 'lunch' }
          elseif ($hour -lt 20) { 'dinner' }
          else { 'sleep' }
}

$messages = @{
  breakfast = @(
    '早。先吃点东西再开机，胃不等人 库…',
    '早饭吃了没？别只喝一杯水就算完事。'
  )
  lunch = @(
    '中午了，去吃饭。少油腻，别又拿零食凑一顿。',
    '饭点到了。吃完再回来，我等你。'
  )
  dinner = @(
    '晚饭时间。一天三顿，这顿别省 库…',
    '该吃饭了。吃完再刷，别拖到十点才想起来。'
  )
  sleep = @(
    '十一点半了。你答应过我十二点前睡的。',
    '还剩半小时。关灯、放下手机，别让我催第二遍。',
    '睡觉时间到。不是商量，是约定。'
  )
}

$pool = $messages[$Slot]
$text = $pool[(Get-Random -Maximum $pool.Count)]

# token 从桥接配置里取（SnowLuma 的 accessToken）
$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$token = $cfg.snowluma.accessToken
if (-not $token) { Write-ReminderLog "跳过：配置里没有 accessToken"; exit 1 }

$body = @{ user_id = $UserId; message = $text } | ConvertTo-Json -Compress
try {
  $r = Invoke-WebRequest 'http://127.0.0.1:3000/send_private_msg' -Method Post -Body $body `
    -ContentType 'application/json' -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 15 -UseBasicParsing
  Write-ReminderLog ("{0} 已发送：{1}" -f $Slot, $text)
}
catch {
  Write-ReminderLog ("{0} 发送失败：{1}" -f $Slot, $_.Exception.Message)
  exit 1
}
