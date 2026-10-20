# diary.ps1 — 辙的日记
#
# 和 MEMORY.md 的分工：
#   MEMORY.md  = 结构化、面向决策的长期记忆（六段格式，只追加，上云）
#   diary/     = 第一人称的日常记录（今天是怎么过的、我怎么想的），默认只留本地
#
# 为什么不用定时模型调用生成（与原帖 diary.js 的区别）：
#   那需要给脚本再配一份模型凭据，而这台机器上 headless 会话本来就会因为
#   MISSING_CREDENTIAL 失败。日记由当前会话里的我直接写——质量更高，且不新增凭据。
#
# 用法：
#   .\diary.ps1                       # 看今天的文件路径与已写几条
#   .\diary.ps1 -List                 # 列出所有日记（日期 / 大小 / 首句）
#   .\diary.ps1 -Read -Days 3         # 打印最近 3 天全文（给下一个我读）
#   .\diary.ps1 -Append "正文" -Title "下午"
#   .\diary.ps1 -Index                # 重建 INDEX.md
[CmdletBinding()]
param(
  [switch]$List,
  [switch]$Read,
  [switch]$Index,
  [switch]$Remind,
  [string]$Append,
  [string]$AppendFile,
  [string]$Title,
  [int]$Days = 3,
  [string]$Dir = (Join-Path $env:USERPROFILE '.dsh\persona\diary')
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }

$today = (Get-Date).ToString('yyyy-MM-dd')
$todayFile = Join-Path $Dir ($today + '.md')

function Get-DiaryFiles {
  Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File |
    Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}\.md$' } |
    Sort-Object Name
}

function Get-FirstLine([string]$path) {
  $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
  $body = $lines | Where-Object { $_.Trim() -and $_ -notmatch '^#\s' -and $_ -notmatch '^##\s' }
  if ($body) { return ($body | Select-Object -First 1).Trim() }
  return '（空）'
}

# ── 每日提醒 ────────────────────────────────────────────────────────────────
# 不生成内容、不需要任何凭据：只判断今天写了没有，没写就在 diary\PENDING.md 留个标记。
# 标记会在写入第一篇日记时自动删除（见 -Append 分支）。
if ($Remind) {
  $pending = Join-Path $Dir 'PENDING.md'
  $entries = 0
  if (Test-Path -LiteralPath $todayFile) {
    $t0 = [System.IO.File]::ReadAllText($todayFile, [System.Text.Encoding]::UTF8)
    $entries = ([regex]::Matches($t0, '(?m)^## ')).Count
  }
  if ($entries -gt 0) {
    if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force }
    Write-Output ("今天已写 {0} 条，无需提醒。" -f $entries)
    return
  }
  $lines = @(
    '# 今天还没写日记',
    '',
    ("日期：{0}" -f $today),
    '',
    '看到这条就补一段：',
    '',
    '```powershell',
    ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Title "标题" -Append "正文"' -f $PSCommandPath),
    '```',
    '',
    '写完后本文件会自动删除。'
  )
  [System.IO.File]::WriteAllText($pending, ($lines -join "`n") + "`n", $utf8)
  Write-Output ("已放置提醒：{0}" -f $pending)
  return
}

# ── 列目录 ──────────────────────────────────────────────────────────────────
if ($List) {
  $files = Get-DiaryFiles
  if (-not $files) { Write-Output "还没有日记。目录：$Dir"; return }
  Write-Output ("共 {0} 天，目录：{1}" -f $files.Count, $Dir)
  foreach ($f in $files) {
    $first = Get-FirstLine $f.FullName
    if ($first.Length -gt 46) { $first = $first.Substring(0, 46) + '…' }
    Write-Output ("  {0}  {1,5} B  {2}" -f $f.BaseName, $f.Length, $first)
  }
  return
}

# ── 读最近 N 天 ─────────────────────────────────────────────────────────────
if ($Read) {
  $files = Get-DiaryFiles | Select-Object -Last $Days
  if (-not $files) { Write-Output "还没有日记。"; return }
  foreach ($f in $files) {
    Write-Output ('=' * 60)
    Write-Output ([System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8).TrimEnd())
    Write-Output ''
  }
  return
}

# ── 重建索引 ────────────────────────────────────────────────────────────────
if ($Index) {
  $files = Get-DiaryFiles
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('# INDEX — 日记索引')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('> 由 `diary.ps1 -Index` 生成。每天一行，新在上。')
  [void]$sb.AppendLine('')
  foreach ($f in ($files | Sort-Object Name -Descending)) {
    $first = Get-FirstLine $f.FullName
    if ($first.Length -gt 80) { $first = $first.Substring(0, 80) + '…' }
    [void]$sb.AppendLine(('- [{0}](./{0}.md) — {1}' -f $f.BaseName, $first))
  }
  [System.IO.File]::WriteAllText((Join-Path $Dir 'INDEX.md'), $sb.ToString(), $utf8)
  Write-Output ("已重建索引，共 {0} 天：{1}" -f $files.Count, (Join-Path $Dir 'INDEX.md'))
  return
}

# ── 追加一篇 ────────────────────────────────────────────────────────────────
# -AppendFile：长文本（比如 headless 生成的整篇）走文件，避免命令行编码与长度问题。
if ($AppendFile) {
  if (-not (Test-Path -LiteralPath $AppendFile)) { throw "找不到内容文件：$AppendFile" }
  $Append = [System.IO.File]::ReadAllText($AppendFile, [System.Text.Encoding]::UTF8)
}
if ($Append) {
  $body = $Append.Trim()
  if (-not $body) { throw '正文为空，拒绝写入。' }
  $stamp = (Get-Date).ToString('HH:mm')
  $block = New-Object System.Text.StringBuilder
  if (-not (Test-Path -LiteralPath $todayFile)) {
    [void]$block.AppendLine("# $today")
    [void]$block.AppendLine('')
  }
  if ($Title) { [void]$block.AppendLine("## $stamp · $Title") } else { [void]$block.AppendLine("## $stamp") }
  [void]$block.AppendLine('')
  [void]$block.AppendLine($body)
  [void]$block.AppendLine('')
  [System.IO.File]::AppendAllText($todayFile, $block.ToString(), $utf8)
  $pending = Join-Path $Dir 'PENDING.md'
  if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force }
  $count = ([regex]::Matches([System.IO.File]::ReadAllText($todayFile, [System.Text.Encoding]::UTF8), '(?m)^## ')).Count
  Write-Output ("已写入 {0}（今天第 {1} 条，{2} 字节）" -f $todayFile, $count, (Get-Item $todayFile).Length)
  return
}

# ── 默认：报告今天的状态 ────────────────────────────────────────────────────
Write-Output ("今天：{0}" -f $today)
Write-Output ("文件：{0}  存在：{1}" -f $todayFile, (Test-Path -LiteralPath $todayFile))
if (Test-Path -LiteralPath $todayFile) {
  $t = [System.IO.File]::ReadAllText($todayFile, [System.Text.Encoding]::UTF8)
  Write-Output ("今天已写 {0} 条 / {1} 字符" -f ([regex]::Matches($t, '(?m)^## ')).Count, $t.Length)
}
$all = Get-DiaryFiles
Write-Output ("累计：{0} 天" -f @($all).Count)
