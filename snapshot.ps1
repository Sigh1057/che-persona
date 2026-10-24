# snapshot.ps1 — 每轮对话后给上下文文件留一份快照
#
# 为什么要有这个：DSH 的上下文会被自动压缩（压缩不是我发起的，我也收不到通知），
# 一压，前面的细节就变成粗摘要。所以每轮变化都留一份原始快照，事后还能翻回去查。
#
# 规则（主人 2026-10-24 要求"每一次都要做"）：
#   1. 只处理最近 10 分钟内变过的会话文件，没变就不复制（避免无意义堆积）
#   2. 每个会话最多留 MAX_KEEP 份，超出按时间删最旧
#   3. 全部内容本地存，不联网；远端推送由 context-sync.ps1 定时做
#   4. 每次运行都写日志，包括"跳过"的原因——没有日志就等于没做

param(
  [string]$SessionRoot = "$env:USERPROFILE\.dsh\sessions",
  [string]$BackupRoot  = 'G:\DHS\context-history',
  [int]$MaxKeep        = 60,
  [int]$FreshMinutes   = 10,
  [string]$LogPath     = 'G:\DHS\context-history\snapshot.log'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

function Log([string]$msg) {
  Add-Content -LiteralPath $LogPath -Value "[$stamp] $msg" -Encoding UTF8
}

try {
  if (-not (Test-Path $SessionRoot)) { Log "跳过：会话目录不存在 $SessionRoot"; exit 0 }

  # 会话快照文件可能是 session.v4.jsonl.zstd，也可能只是 .jsonl，两种都收
  $files = Get-ChildItem $SessionRoot -Recurse -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like 'session*' -and ($_.Extension -in '.zstd', '.jsonl', '.json') }

  $now = Get-Date
  $copied = 0
  foreach ($f in $files) {
    $age = ($now - $f.LastWriteTime).TotalMinutes
    if ($age -gt $FreshMinutes) { continue }

    # 会话 id 用父目录名，保证同一会话的快照放一起
    $sid = $f.Directory.Name
    $destDir = Join-Path $BackupRoot $sid
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null

    # 去重：已经有一份和当前一模一样的（大小+写入时间）就不再复制
    $marker = Join-Path $destDir 'last.txt'
    $sig = "{0}|{1}" -f $f.Length, $f.LastWriteTimeUtc.ToString('o')
    if (Test-Path $marker) {
      $old = (Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue).Trim()
      if ($old -eq $sig) { continue }
    }

    $dest = Join-Path $destDir ("{0}_{1}{2}" -f $f.LastWriteTime.ToString('yyyyMMdd-HHmmss'), $f.BaseName, $f.Extension)
    Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
    Set-Content -LiteralPath $marker -Value $sig -Encoding UTF8
    $copied++

    # 只留最近 MaxKeep 份
    $all = Get-ChildItem $destDir -File | Where-Object { $_.Name -ne 'last.txt' } | Sort-Object LastWriteTime -Descending
    if ($all.Count -gt $MaxKeep) {
      $all | Select-Object -Skip $MaxKeep | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    }
  }

  if ($copied -gt 0) { Log "完成：新快照 $copied 份（每个会话最多留 $MaxKeep 份）" }
  else { Log "本轮无变化，未复制" }
}
catch {
  Log ("失败：" + $_.Exception.Message)
  exit 1
}
