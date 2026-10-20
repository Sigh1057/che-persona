# index.ps1 — 给 MEMORY.md 建主题索引
#
# 为什么需要它：
#   MEMORY.md 现在两万多字符、二十多条，而 che-recall 的约定只读「当前状态 + 最近 3 条」。
#   也就是说大部分旧记忆虽然存在，却没有入口。索引把「按时间」的线性文件补上「按主题」
#   的检索面，让我能按关键词定位到具体条目再读，而不是通读或干脆不读。
#
# 与 MEMORY.md 的关系：
#   本脚本只读不写 MEMORY.md，产物是独立的 MEMORY-INDEX.md；不改条目、不加字段，
#   所以 append-only 的契约不受影响。
#
# 用法：
#   .\index.ps1            # 重建 MEMORY-INDEX.md
#   .\index.ps1 -Show      # 顺带打印摘要
[CmdletBinding()]
param(
  [string]$MemoryPath = (Join-Path $env:USERPROFILE '.dsh\persona\MEMORY.md'),
  [string]$OutPath    = (Join-Path $env:USERPROFILE '.dsh\persona\MEMORY-INDEX.md'),
  [switch]$Show
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
if (-not (Test-Path -LiteralPath $MemoryPath)) { throw "找不到 MEMORY.md：$MemoryPath" }

$text = [System.IO.File]::ReadAllText($MemoryPath, [System.Text.Encoding]::UTF8)
$lines = $text -split "`r?`n"

# ── 主题词表：命中越多越贴题；同一条可落进多个主题 ────────────────────────
$TOPICS = [ordered]@{
  '凭据与安全' = @('凭据','token','密钥','泄露','权限','scope','探针','截图','暴露','撤销')
  '记忆与人格' = @('记忆','人格','PERSONA','MEMORY','派生','角色卡','条目','注入','摘要')
  'QQ 与接入'  = @('QQ','qq-bridge','SnowLuma','桥接','MCP','群聊','预设')
  '环境与运行时' = @('DSH','node','端口','代理','证书','git','PowerShell','BOM','机器','换机')
  '日记与自省' = @('日记','diary','自省','think','headless')
  '工具链'     = @('脚本','计划任务','心跳','备份','私有仓库','索引','合并')
}

# ── 切条目 ─────────────────────────────────────────────────────────────────
$entries = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '^### (\d{4}-\d{2}-\d{2}) · (.+)$') {
    $entries += [pscustomobject]@{ date = $Matches[1]; title = $Matches[2].Trim(); line = $i }
  }
}
if ($entries.Count -eq 0) { Write-Output '没有找到条目。'; return }

# 每条正文范围：本条起始到下一条起始
for ($k = 0; $k -lt $entries.Count; $k++) {
  $start = $entries[$k].line
  $end = if ($k + 1 -lt $entries.Count) { $entries[$k + 1].line } else { $lines.Count }
  $body = ($lines[$start..($end - 1)] -join "`n")
  $entries[$k] | Add-Member -NotePropertyName body -NotePropertyValue $body -Force

  $hits = @()
  $byTopic = @{}
  $title = $entries[$k].title
  foreach ($t in $TOPICS.Keys) {
    $bodyHits = 0
    $titleHits = 0
    foreach ($w in $TOPICS[$t]) {
      if ($body -match [regex]::Escape($w)) { $hits += $w; $bodyHits++ }
      if ($title -match [regex]::Escape($w)) { $titleHits++ }
    }
    # 标题命中权重 3：一条记忆的标题通常就是它最想被检索到的词，
    # 否则「所有条目都提到记忆/凭据」会把每个主题都塞满。
    $score = 3 * $titleHits + $bodyHits
    if ($score -gt 0) { $byTopic[$t] = $score }
  }
  # 只保留主主题（得分最高且唯一），保证每条只出现在一个桶里，索引才是导航而不是清单。
  $primary = ''
  if ($byTopic.Count -gt 0) {
    $primary = ($byTopic.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
  }
  $entries[$k] | Add-Member -NotePropertyName topic -NotePropertyValue $primary -Force
  $entries[$k] | Add-Member -NotePropertyName score -NotePropertyValue ($(if ($primary) { $byTopic[$primary] } else { 0 })) -Force
  $uniq = @($hits | Select-Object -Unique)
  $entries[$k] | Add-Member -NotePropertyName keywords -NotePropertyValue ($uniq | Select-Object -First 6) -Force
}

# ── 组装索引 ───────────────────────────────────────────────────────────────
$head = New-Object System.Collections.Generic.List[string]
[void]$head.Add('# MEMORY 索引 — 按主题')
[void]$head.Add('')
[void]$head.Add(('> 由 `index.ps1` 生成，只读 `MEMORY.md`，不改任何条目。**{0} 条 / {1} 字符**。' -f $entries.Count, $text.Length))
[void]$head.Add('> 用途：`MEMORY.md` 是按时间的线；这个文件是按主题的面。要精确定位用 `memctx.ps1 -Search <关键词>`。')
[void]$head.Add('')

$bodyOut = New-Object System.Collections.Generic.List[string]
$uncategorized = @()

foreach ($topic in $TOPICS.Keys) {
  $hits = @($entries | Where-Object { $_.topic -eq $topic } |
    Sort-Object score -Descending)
  if ($hits.Count -eq 0) { continue }
  [void]$bodyOut.Add(('## {0}（{1} 条）' -f $topic, $hits.Count))
  [void]$bodyOut.Add('')
  foreach ($e in $hits) {
    $kw = ''
    if (@($e.keywords).Count -gt 0) { $kw = ' ｜ ' + (@($e.keywords) -join '、') }
    [void]$bodyOut.Add(('- {0} · {1}{2}' -f $e.date, $e.title, $kw))
  }
  [void]$bodyOut.Add('')
}

$uncategorized = @($entries | Where-Object { -not $_.topic })
if ($uncategorized.Count -gt 0) {
  [void]$bodyOut.Add(('## 未归类（{0} 条）' -f $uncategorized.Count))
  [void]$bodyOut.Add('')
  foreach ($e in $uncategorized) { [void]$bodyOut.Add(('- {0} · {1}' -f $e.date, $e.title)) }
  [void]$bodyOut.Add('')
}

# ── 按时间 ─────────────────────────────────────────────────────────────────
[void]$bodyOut.Add('## 全部条目（按时间倒序）')
[void]$bodyOut.Add('')
foreach ($e in ($entries | Sort-Object date, title -Descending)) {
  $t = if ($e.topic) { ' ｜ ' + $e.topic } else { '' }
  [void]$bodyOut.Add(('- {0} · {1}{2}' -f $e.date, $e.title, $t))
}
[void]$bodyOut.Add('')

$out = (($head + $bodyOut) -join "`n")
[System.IO.File]::WriteAllText($OutPath, $out, $utf8)
$topicCount = @($entries | Where-Object { $_.topic } | Group-Object topic).Count
Write-Output ('已生成索引：{0}（{1} 条 → 命中 {2} 个主题，未归类 {3} 条）' -f $OutPath, $entries.Count, $topicCount, $uncategorized.Count)
if ($Show) { Write-Output ''; Write-Output $out }
