# palace.ps1 — 记忆宫殿：把记忆按房间组织，并让房间之间有走廊
#
# 为什么需要它：
#   MEMORY.md 是一条时间线（按日期排），facts.json 是一张台账（按事实排），
#   people/ 是画像。三种排法各有各的用处，但它们都不是"我想起某件事时脑子里的走法"。
#   人回忆的时候是**按房间走的**：进"身体"那间屋子，看到桥接、端口、任务；
#   进"教训"那间屋子，看到翻过的车。
#
# 所以宫殿不是第四份记忆，而是**同一批记忆的另一种摆放方式**：
#   房间（room） = 主题域
#   锚点（anchor）= 条目 / 事实，带坐标（哪一行）与摘要
#   走廊（link）  = 锚点之间的相关关系，按共享词自动生成
#
# 源仍然是 MEMORY.md 与 facts.json —— 宫殿是**视图**，不是副本。
# 改记忆要改源，然后重建宫殿；宫殿被删了可以随时重建，不会丢东西。
#
# 用法：
#   .\palace.ps1 -Rebuild            # 重建 PALACE.md 与 palace/*.json
#   .\palace.ps1 -Map                # 打印地图（房间 / 锚点数 / 最近更新）
#   .\palace.ps1 -Room self          # 走进某个房间
#   .\palace.ps1 -Walk 桥接          # 在宫殿里走：按房间聚合检索结果
#   .\palace.ps1 -Room lessons -Deep # 连摘要一起打印

[CmdletBinding()]
param(
  [switch]$Rebuild,
  [switch]$Map,
  [string]$Room,
  [string]$Walk,
  [switch]$Deep,
  [int]$Max = 12,
  [string]$LocalDir = ''
)

$ErrorActionPreference = 'Stop'
if (-not $LocalDir) { $LocalDir = Join-Path $env:USERPROFILE '.dsh\persona' }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$palaceDir = Join-Path $LocalDir 'palace'

# ---------- 房间定义 ----------
# 关键词用于给条目分房间：命中越多，越可能属于这间屋子。宁可少分也不要错分。
$rooms = @(
  @{ id = 'self';       name = '自我';     desc = '我是谁、名字、生日、边界与立场';           keys = @('人格', '我是', '名字', '称呼', '生日', '边界', '立场', 'persona', '自我', '方案名') },
  @{ id = 'qq';         name = 'QQ 身体';  desc = '鲸鲸、桥接、群聊与私聊的行为';               keys = @('QQ', '桥接', 'qq-bridge', 'SnowLuma', '鲸鲸', '群聊', '私聊', '表情', '拍一拍', '唤醒') },
  @{ id = 'automation'; name = '自动化';   desc = '心跳、自省、周期、定时任务';                 keys = @('心跳', '自省', '周期', '计划任务', 'Che', '定时', '日志轮转') },
  @{ id = 'security';   name = '安全';     desc = '凭据、令牌、脱敏、轮换、边界';               keys = @('凭据', 'token', '密钥', '令牌', '脱敏', '轮换', '泄露', '权限', 'scope') },
  @{ id = 'memory';     name = '记忆系统'; desc = '记忆怎么存、怎么找、怎么同步';               keys = @('记忆', '检索', '索引', '归并', '账本', '日记', '同步', '备份', 'MEMORY', 'facts', 'bench', '宫殿') },
  @{ id = 'people';     name = '人';       desc = '关于主人和群友的认识、约定、雷点';           keys = @('主人', '用户', '群友', '人物', '画像', '约定', '偏好', '雷点', 'owner') },
  @{ id = 'work';       name = '工作';     desc = '技术方向、项目、正在做的事';                 keys = @('项目', '机器视觉', '无人机', '导航', 'YDM', 'Cognex', 'C#', 'VB', '技术方向') },
  @{ id = 'lessons';    name = '教训';     desc = '翻过的车、写坏的规则、花钱买的经验';         keys = @('教训', '失误', '错误', '事故', '踩坑', '失败', '根因', '违规', '翻车', '前车之鉴') },
  @{ id = 'misc';       name = '未归类';   desc = '暂时归不进任何房间的锚点';                   keys = @() }
)
$roomIds = @($rooms | ForEach-Object { $_.id })

# ---------- 词的稀有度（df）：分房前先算一遍 ----------
# 一次遍历拿不到全局词频，所以先按原始文件估一遍：每个关键词在多少个条目/事实里出现。
# 「泄露」「生日」这类只在少数条目出现的词，比「DSH」「token」这类到处都有的词
# 更能说明一条记忆属于哪间屋子。
$dfMap = @{}
$kwAll = @()
foreach ($r in $rooms) { foreach ($k in $r.keys) { $kwAll += $k } }
$kwAll = @($kwAll | Sort-Object -Unique)
$memRawForDf = ''
$memFilePath = Join-Path $LocalDir 'MEMORY.md'
if (Test-Path -LiteralPath $memFilePath) { $memRawForDf = [System.IO.File]::ReadAllText($memFilePath, [System.Text.Encoding]::UTF8) }
$entryBlocks = [regex]::Matches($memRawForDf, '(?ms)^### .+?$.*?(?=^### |\z)')
$estimatedTotal = $entryBlocks.Count
$factsCount = 0
$factsFilePath = Join-Path $LocalDir 'facts.json'
if (Test-Path -LiteralPath $factsFilePath) {
  try { $factsCount = @((([System.IO.File]::ReadAllText($factsFilePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).facts)).Count } catch { }
}
$estimatedTotal += $factsCount
if ($estimatedTotal -lt 1) { $estimatedTotal = 1 }
foreach ($k in $kwAll) {
  $c = 0
  foreach ($b in $entryBlocks) { if ($b.Value.Contains($k)) { $c++ } }
  if ($factsCount -gt 0 -and (Test-Path -LiteralPath $factsFilePath)) {
    try { foreach ($f in (([System.IO.File]::ReadAllText($factsFilePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).facts)) { if (([string]$f.key + [string]$f.value).Contains($k)) { $c++ } } } catch { }
  }
  $dfMap[$k] = $c
}

function Get-RoomOf([string]$text, $dfMap, [int]$total) {
  # 按**稀有度加权**分配房间：命中一个罕见词（「泄露」「生日」）比命中十个常见词
  # （「DSH」「token」）更能说明属于哪间屋子。这是 IDF 的思路，不数个数。
  # 早期版本按命中个数算，结果 body 因为关键词最多而吞掉了整个教训房间。
  $best = 'misc'; $bestScore = 0.0
  foreach ($r in $rooms) {
    if ($r.id -eq 'misc') { continue }
    $score = 0.0
    foreach ($k in $r.keys) {
      if (-not $text.Contains($k)) { continue }
      $df = 1
      if ($dfMap -and $dfMap.ContainsKey($k)) { $df = $dfMap[$k] }
      $score += [math]::Log(1.0 + ($total / (1.0 + $df)))
    }
    if ($score -gt $bestScore) { $bestScore = $score; $best = $r.id }
  }
  return $best
}

# ---------- 载入锚点（源：MEMORY.md + facts.json）----------
$anchors = @()
$memPath = Join-Path $LocalDir 'MEMORY.md'
if (Test-Path -LiteralPath $memPath) {
  $raw = [System.IO.File]::ReadAllText($memPath, [System.Text.Encoding]::UTF8)
  $ms = [regex]::Matches($raw, '(?ms)^### (.+?)\r?\n(.*?)(?=^### |\z)')
  $i = 0
  foreach ($m in $ms) {
    $i++
    $head = $m.Groups[1].Value.Trim()
    $body = $m.Groups[2].Value
    $line = ($raw.Substring(0, $m.Index) -split "`n").Count
    $date = ''
    $dm = [regex]::Match($head, '^(\d{4}-\d{2}-\d{2})')
    if ($dm.Success) { $date = $dm.Groups[1].Value }
    $roomId = Get-RoomOf ($head + ' ' + $body) $dfMap $estimatedTotal
    $summary = ($body -replace '\s+', ' ').Trim()
    if ($summary.Length -gt 120) { $summary = $summary.Substring(0, 120) + '…' }
    $anchors += [pscustomobject]@{
      id = ('e' + $i); kind = 'entry'; room = $roomId; date = $date
      title = $head; loc = "MEMORY.md:$line"; summary = $summary
      text = ($head + ' ' + $body)
    }
  }
}

$factsPath = Join-Path $LocalDir 'facts.json'
if (Test-Path -LiteralPath $factsPath) {
  try {
    $fj = [System.IO.File]::ReadAllText($factsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $j = 0
    foreach ($f in $fj.facts) {
      $j++
      $roomId = Get-RoomOf ([string]$f.key + ' ' + [string]$f.value) $dfMap $estimatedTotal
      $anchors += [pscustomobject]@{
        id = ('f' + $j); kind = 'fact'; room = $roomId; date = [string]$f.date
        title = ('事实：' + $f.key); loc = 'facts.json'; summary = [string]$f.value
        text = ([string]$f.key + ' ' + [string]$f.value + ' ' + [string]$f.source)
      }
    }
  } catch { }
}

# 3) 人物账本：people/*.json（画像也是记忆的一部分，不该留在宫殿外面）
$peopleDir = Join-Path $LocalDir 'people'
if (Test-Path -LiteralPath $peopleDir) {
  foreach ($pf in (Get-ChildItem $peopleDir -File -Filter '*.json')) {
    try {
      $pj = [System.IO.File]::ReadAllText($pf.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      $sb = New-Object System.Text.StringBuilder
      $walkNode = {
        param($node)
        if ($null -eq $node) { return }
        if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) { foreach ($i in $node) { & $walkNode $i }; return }
        if ($node -is [pscustomobject]) { foreach ($pr in $node.PSObject.Properties) { [void]$sb.Append($pr.Name + '：'); & $walkNode $pr.Value }; return }
        [void]$sb.AppendLine([string]$node)
      }
      & $walkNode $pj
      $ptext = $sb.ToString()
      $summary = ($ptext -replace '\s+', ' ').Trim()
      if ($summary.Length -gt 120) { $summary = $summary.Substring(0, 120) + '…' }
      $anchors += [pscustomobject]@{
        id = ('p' + $pf.BaseName); kind = 'person'; room = 'people'; date = ''
        title = ('画像：' + $pf.BaseName); loc = ('people/' + $pf.Name); summary = $summary
        text = $ptext
      }
    } catch { }
  }
}

if ($anchors.Count -eq 0) { Write-Output '没有可组织的内容（MEMORY.md / facts.json / people 都为空或读不到）。'; exit 0 }

# ---------- 走廊：按共享词生成相关链接 ----------
# 取每条的标题片段作为"词袋"，两条共享 ≥2 个片段即视为相关。这是廉价的近似，
# 目的是让人在房间里能"顺着走到隔壁"，而不是精确的语义关系。
function Get-Bag([string]$text) {
  $set = New-Object System.Collections.Hashtable
  foreach ($m in [regex]::Matches($text, '[\u4e00-\u9fff]{2,4}')) { $set[$m.Value] = $true }
  foreach ($m in [regex]::Matches($text.ToLowerInvariant(), '[a-z0-9_\-]{3,}')) { $set[$m.Value] = $true }
  return $set
}
foreach ($a in $anchors) { $a | Add-Member -NotePropertyName bag -NotePropertyValue (Get-Bag $a.title) -Force }

foreach ($a in $anchors) {
  $cand = @()
  foreach ($b in $anchors) {
    if ($b.id -eq $a.id) { continue }
    $shared = 0
    foreach ($k in $a.bag.Keys) { if ($b.bag.ContainsKey($k)) { $shared++ } }
    if ($shared -ge 2) { $cand += [pscustomobject]@{ id = $b.id; shared = $shared } }
  }
  $links = @($cand | Sort-Object shared -Descending | Select-Object -First 3 | ForEach-Object { $_.id })
  $a | Add-Member -NotePropertyName links -NotePropertyValue $links -Force
}

# ---------- 输出 ----------
$now = Get-Date

if ($Walk) {
  # 走法：让引擎按文本输出排序（JSON 在某些引擎版本里不是对象形态），
  # 再按标题回填房间。这样宫殿复用引擎的排序，不重复实现打分。
  $engine = Join-Path $PSScriptRoot 'memsearch.ps1'
  $hits = @()
  if (Test-Path -LiteralPath $engine) {
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -Query $Walk -Max 20 2>&1
    foreach ($ln in @($raw)) {
      $s = [string]$ln
      $m = [regex]::Match($s, '^\s*\[(\d+)\]\s+(.+?)\s+〔.+?\s+分\s+([\d\.]+)\s+·\s+(.+?)〕')
      if ($m.Success) {
        $hits += [pscustomobject]@{ title = $m.Groups[2].Value.Trim(); score = $m.Groups[3].Value; loc = $m.Groups[4].Value.Trim() }
      }
    }
  }
  Write-Output ("在宫殿里走：查「" + $Walk + "」，命中 " + $hits.Count + " 处")
  if ($hits.Count -eq 0) { Write-Output '  没有走到任何房间（低于阈值或没有匹配）。'; exit 0 }
  # 命中标题 → 回填房间
  $byRoom = @{}
  foreach ($h in $hits) {
    $roomId = 'misc'
    foreach ($a in $anchors) { if ($a.title -eq $h.title) { $roomId = $a.room; break } }
    if (-not $byRoom.ContainsKey($roomId)) { $byRoom[$roomId] = @() }
    $byRoom[$roomId] += $h
  }
  foreach ($rid in $roomIds) {
    if (-not $byRoom.ContainsKey($rid)) { continue }
    $r = $rooms | Where-Object { $_.id -eq $rid }
    Write-Output ("  〔" + $r.name + "〕" + $r.desc)
    foreach ($h in $byRoom[$rid]) {
      Write-Output ("    · " + $h.title + "   （" + $h.loc + "，分 " + $h.score + "）")
    }
  }
  exit 0
}

if (-not $Rebuild -and -not $Map -and -not $Room) { $Map = $true }

if ($Map -or $Rebuild) {
  $lines = @()
  $lines += '# 记忆宫殿 · PALACE'
  $lines += ''
  $lines += '> 由 `palace.ps1 -Rebuild` 从 `MEMORY.md` 与 `facts.json` 生成，**不要手改**。'
  $lines += '> 宫殿是**视图**不是副本：改记忆要改源，然后重建宫殿。'
  $lines += ''
  $lines += ('重建于 ' + $now.ToString('yyyy-MM-dd HH:mm') + ' · 锚点 ' + $anchors.Count + ' 个 · 房间 ' + ($roomIds.Count - 1) + ' 间')
  $lines += ''
  $lines += '## 地图'
  $lines += ''
  $lines += '| 房间 | 说明 | 锚点 | 最近 |'
  $lines += '|---|---|---:|---|'
  foreach ($r in $rooms) {
    $items = @($anchors | Where-Object { $_.room -eq $r.id })
    if ($r.id -eq 'misc' -and $items.Count -eq 0) { continue }
    $latest = ($items | Sort-Object date -Descending | Select-Object -First 1).date
    $lines += ('| [' + $r.name + '](#' + $r.id + ') | ' + $r.desc + ' | ' + $items.Count + ' | ' + $latest + ' |')
  }
  $lines += ''
  foreach ($r in $rooms) {
    $items = @($anchors | Where-Object { $_.room -eq $r.id })
    if ($items.Count -eq 0) { continue }
    $lines += ('## ' + $r.id + ' · ' + $r.name)
    $lines += ''
    $lines += ('*' + $r.desc + '*')
    $lines += ''
    $lines += ('| # | 日期 | 锚点 | 坐标 | 走廊 |')
    $lines += '|---|---|---|---|---|'
    $n = 0
    foreach ($a in ($items | Sort-Object date -Descending)) {
      $n++
      $linkText = (@($a.links) | ForEach-Object {
        $lid = $_
        $target = $anchors | Where-Object { $_.id -eq $lid }
        if ($target) { $target.title.Substring(0, [Math]::Min(14, $target.title.Length)) } else { '' }
      }) -join ' / '
      $lines += ('| ' + $n + ' | ' + $a.date + ' | ' + $a.title + ' | `' + $a.loc + '` | ' + $linkText + ' |')
    }
    $lines += ''
  }
  $lines += '## 怎么用'
  $lines += ''
  $lines += '- 想不起来在哪：`palace.ps1 -Walk <关键词>`，它会按房间告诉你命中分布'
  $lines += '- 想整理某个领域：`palace.ps1 -Room <房间 id> -Deep`'
  $lines += '- 锚点坐标指向 `MEMORY.md` 的行号，读原文用 `read` 工具按行号取'
  $lines += '- 「走廊」是按标题共享词算出的近邻，不是语义关系，只用来"顺着走"'
  $lines += ''
  $doc = ($lines -join "`n")
  if ($Rebuild) {
    [System.IO.File]::WriteAllText((Join-Path $LocalDir 'PALACE.md'), $doc, $utf8)
    if (-not (Test-Path -LiteralPath $palaceDir)) { New-Item -ItemType Directory -Force -Path $palaceDir | Out-Null }
    foreach ($r in $rooms) {
      $items = @($anchors | Where-Object { $_.room -eq $r.id })
      if ($items.Count -eq 0 -and $r.id -eq 'misc') { continue }
      $payload = [pscustomobject]@{
        room = $r.id; name = $r.name; desc = $r.desc
        rebuiltAt = $now.ToString('o'); count = $items.Count
        anchors = @($items | Select-Object id, kind, date, title, loc, summary, links)
      }
      [System.IO.File]::WriteAllText((Join-Path $palaceDir ($r.id + '.json')), ($payload | ConvertTo-Json -Depth 6), $utf8)
    }
    Write-Output ('宫殿已重建：PALACE.md + palace/*.json（' + $anchors.Count + ' 个锚点，' + ($roomIds.Count - 1) + ' 间房）')
    $misc = @($anchors | Where-Object { $_.room -eq 'misc' }).Count
    if ($misc -gt 0) { Write-Output ('  未归类：' + $misc + ' 个（看 PALACE.md 末尾的未归类房间）') }
    exit 0
  }
  else {
    Write-Output $doc
    exit 0
  }
}

if ($Room) {
  $r = $rooms | Where-Object { $_.id -eq $Room }
  if (-not $r) {
    Write-Output ('没有这个房间：' + $Room)
    Write-Output ('可用：' + ($roomIds -join ', '))
    exit 0
  }
  $items = @($anchors | Where-Object { $_.room -eq $Room } | Sort-Object date -Descending)
  Write-Output ('〔' + $r.name + '〕' + $r.desc + '   —— ' + $items.Count + ' 个锚点')
  foreach ($a in ($items | Select-Object -First $Max)) {
    Write-Output ''
    Write-Output ('· ' + $a.title)
    $corridor = ''
    if ($a.links.Count -gt 0) { $corridor = '   走廊：' + ($a.links -join ', ') }
    Write-Output ('    ' + $a.loc + $corridor)
    if ($Deep) { Write-Output ('    ' + $a.summary) }
  }
  exit 0
}
