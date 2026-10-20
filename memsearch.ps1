# memsearch.ps1 — 记忆检索引擎（借鉴 MaiBot A_Memorix 的检索设计）
#
# 与旧版（memctx -Search 的直接子串匹配）的区别：
#   1. **打分而不只是匹配**：BM25 式（词频 × 逆文档频率 ÷ 长度归一化）
#   2. **字段权重**：标题命中 ×3，正文 ×1
#   3. **精确加成**：数字/代码型词（401、che-private）命中 ×2
#   4. **时间衰减**：越新的条目略占优（半衰期约 30 天），但"稳定事实"不衰减
#   5. **阈值**：低于阈值就明说"没有足够匹配"，而不是凑数返回噪声
#   6. **同义词**：密钥↔token↔凭据……
#   7. **分层来源**：memory（情景）/ facts（事实台账）/ people（画像）/ diary（日记）
#
# 这些分层与阈值的设计借鉴自 MaiBot 的 A_Memorix：情景、事实、画像分开存，
# 检索结果过阈值，宁可说没有也不给噪声。实现是独立写的，没有引入向量库。
#
# 用法：
#   .\memsearch.ps1 -Query 生日
#   .\memsearch.ps1 -Query 401 -Explain
#   .\memsearch.ps1 -Query 密钥 -Source facts,memory -Max 3
#   .\memsearch.ps1 -Query token -Json

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Query,
  [int]$Max = 5,
  [string[]]$Source = @('memory', 'facts', 'people', 'diary'),
  [double]$Threshold = 1.0,
  [double]$Relative = 0.30,
  [switch]$Explain,
  [switch]$Json,
  [string]$LocalDir = ''
)

$ErrorActionPreference = 'Stop'
if (-not $LocalDir) { $LocalDir = Join-Path $env:USERPROFILE '.dsh\persona' }

# ---------- 同义词（只做单向扩展：查询词 → 追加词）----------
$SynonymTable = @{
  '密钥'   = @('token', '凭据', '泄露', 'unauthorized')
  'token'  = @('密钥', '凭据', '令牌')
  '凭据'   = @('密钥', 'token', 'credential')
  '生日'   = @('诞辰', '出生')
  '名字'   = @('称呼', '命名', '起名')
  '称呼'   = @('名字', '昵称')
  '记忆'   = @('memory', '档案', '回忆')
  '日记'   = @('diary', '记录')
  '桥接'   = @('bridge', 'qq-bridge')
  '发送失败' = @('unauthorized', '401', '失败')
  '授权'   = @('认证', '鉴权', 'auth')
  '检索'   = @('搜索', '查找', 'search')
  '人格'   = @('persona', '性格')
  '账本'   = @('people', '人物')
}

function Get-Terms([string]$text) {
  $set = New-Object System.Collections.Hashtable
  $lower = $text.ToLowerInvariant()
  # 虚词过滤：中文双字切分把「我是」「是谁」这类组合也切出来，它们几乎在每条记忆里
  # 都命中，会把打分稀释成噪声。这里把"两个字都是虚词"的组合丢掉（单字虚词表 +
  # 高频词组黑名单）。这不是语义理解，只是降噪。
  $stopChars = '的了是我你他她它们在有和与就也都还很吗呢吧啊这那怎么谁什呀嘛哦把被让给对从到会要能'
  $stopBigrams = @('我是', '是你', '是谁', '怎么', '什么', '这个', '那个', '可以', '一个', '我们', '他们', '自己', '没有', '就是', '今天', '昨天', '明天', '现在', '时候', '怎么样', '为什么', '还是', '但是', '而且')
  foreach ($m in [regex]::Matches($lower, '[a-z0-9_\-\.]{2,}')) {
    $t = $m.Value.Trim('.', '-')
    if ($t.Length -ge 2) { $set[$t] = $true }
  }
  foreach ($m in [regex]::Matches($lower, '[\u4e00-\u9fff]{2,}')) {
    $run = $m.Value
    if ($run.Length -le 3) {
      if ($stopBigrams -notcontains $run) { $set[$run] = $true }
    }
    else {
      $set[$run] = $true
      for ($i = 0; $i -lt $run.Length - 1; $i++) {
        $bi = $run.Substring($i, 2)
        if ($stopBigrams -contains $bi) { continue }
        if ($stopChars.Contains($bi[0]) -and $stopChars.Contains($bi[1])) { continue }
        $set[$bi] = $true
      }
    }
  }
  return @($set.Keys)
}

# ---------- 载入文档 ----------
$docs = @()

function Add-Doc([string]$srctag, [string]$title, [string]$body, [string]$date, [string]$loc, [bool]$stable) {
  $script:docs += [pscustomobject]@{
    source = $srctag
    title  = $title
    body   = $body
    date   = $date
    loc    = $loc
    stable = $stable
  }
}

# 1) 情景：MEMORY.md 条目
$memPath = Join-Path $LocalDir 'MEMORY.md'
if (($Source -contains 'memory') -and (Test-Path -LiteralPath $memPath)) {
  $raw = [System.IO.File]::ReadAllText($memPath, [System.Text.Encoding]::UTF8)
  $matches = [regex]::Matches($raw, '(?ms)^### (.+?)\r?\n(.*?)(?=^### |\z)')
  foreach ($m in $matches) {
    $head = $m.Groups[1].Value.Trim()
    $line = ($raw.Substring(0, $m.Index) -split "`n").Count
    $date = ''
    $dm = [regex]::Match($head, '^(\d{4}-\d{2}-\d{2})')
    if ($dm.Success) { $date = $dm.Groups[1].Value }
    Add-Doc 'memory' $head $m.Groups[2].Value $date "MEMORY.md:$line" $false
  }
}

# 2) 事实台账：facts.json
$factsPath = Join-Path $LocalDir 'facts.json'
if (($Source -contains 'facts') -and (Test-Path -LiteralPath $factsPath)) {
  try {
    $fj = [System.IO.File]::ReadAllText($factsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($f in $fj.facts) {
      $body = ("值：" + $f.value + "；来源：" + $f.source)
      Add-Doc 'facts' ("事实：" + $f.key) $body ([string]$f.date) 'facts.json' ([bool]$f.stable)
    }
  } catch { }
}

# 3) 画像：people/*.json
$peopleDir = Join-Path $LocalDir 'people'
if (($Source -contains 'people') -and (Test-Path -LiteralPath $peopleDir)) {
  foreach ($p in (Get-ChildItem $peopleDir -File -Filter '*.json')) {
    try {
      $pj = [System.IO.File]::ReadAllText($p.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      $sb = New-Object System.Text.StringBuilder
      $walk = {
        param($node)
        if ($null -eq $node) { return }
        if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) { foreach ($i in $node) { & $walk $i }; return }
        if ($node -is [pscustomobject]) { foreach ($pr in $node.PSObject.Properties) { [void]$sb.Append($pr.Name + '：'); & $walk $pr.Value }; return }
        [void]$sb.AppendLine([string]$node)
      }
      & $walk $pj
      Add-Doc 'people' ("画像：" + $p.BaseName) $sb.ToString() '' ("people/" + $p.Name) $true
    } catch { }
  }
}

# 4) 日记
$diaryDir = Join-Path $LocalDir 'diary'
if (($Source -contains 'diary') -and (Test-Path -LiteralPath $diaryDir)) {
  foreach ($d in (Get-ChildItem $diaryDir -File -Filter '*.md')) {
    $txt = [System.IO.File]::ReadAllText($d.FullName, [System.Text.Encoding]::UTF8)
    $dm = [regex]::Match($d.BaseName, '(\d{4})-?(\d{2})-?(\d{2})')
    $date = ''
    if ($dm.Success) { $date = "$($dm.Groups[1].Value)-$($dm.Groups[2].Value)-$($dm.Groups[3].Value)" }
    Add-Doc 'diary' ("日记：" + $d.BaseName) $txt $date ("diary/" + $d.Name) $false
  }
}

if ($docs.Count -eq 0) { Write-Output '没有可检索的来源。'; exit 0 }

# ---------- 查询词与权重 ----------
$qTerms = Get-Terms $Query
$weights = @{}
foreach ($t in $qTerms) { $weights[$t] = 1.0 }
foreach ($t in $qTerms) {
  $key = $t
  if ($SynonymTable.ContainsKey($key)) {
    foreach ($s in $SynonymTable[$key]) {
      if (-not $weights.ContainsKey($s)) { $weights[$s] = 0.6 }
    }
  }
}

$N = $docs.Count
$avgLen = ($docs | ForEach-Object { ($_.title.Length + $_.body.Length) } | Measure-Object -Average).Average
if ($avgLen -le 0) { $avgLen = 1 }
$now = Get-Date

# ---------- 打分 ----------
$scored = @()
foreach ($doc in $docs) {
  $tLow = $doc.title.ToLowerInvariant()
  $bLow = $doc.body.ToLowerInvariant()
  $len = $doc.title.Length + $doc.body.Length
  $lenNorm = [math]::Sqrt(1 + ($len / $avgLen))
  $score = 0.0
  $contrib = @()
  foreach ($t in $weights.Keys) {
    $w = $weights[$t]
    $tfT = ([regex]::Matches($tLow, [regex]::Escape($t))).Count
    $tfB = ([regex]::Matches($bLow, [regex]::Escape($t))).Count
    if (($tfT + $tfB) -eq 0) { continue }
    # 文档频率
    $df = 0
    foreach ($d in $docs) { if ($d.title.ToLowerInvariant().Contains($t) -or $d.body.ToLowerInvariant().Contains($t)) { $df++ } }
    $idf = [math]::Log(1 + ($N / (1.0 + $df)))
    $exact = if ($t -match '^[a-z0-9_\-\.]{2,}$' -or $t -match '^\d+$') { 2.0 } else { 1.0 }
    # BM25 词频饱和：tf 增长但收益递减（k1=1.2）。没有饱和时，一条反复出现
    # 某个词的记忆会压过所有其他条目——"今天天气怎么样"能靠一个「今天」拿到 14 分。
    $k1 = 1.2
    $satB = ($tfB * ($k1 + 1)) / ($tfB + $k1)
    $satT = 3.0 * (($tfT * ($k1 + 1)) / ($tfT + $k1))
    $part = $w * $idf * ($satT + $satB) * $exact / $lenNorm
    if ($part -gt 0) {
      $score += $part
      $contrib += [pscustomobject]@{ term = $t; part = [math]::Round($part, 3); tfTitle = $tfT; tfBody = $tfB; idf = [math]::Round($idf, 2) }
    }
  }
  if ($score -le 0) { continue }
  # 时间衰减：稳定事实不衰减
  $boost = 1.0
  if (-not $doc.stable -and $doc.date) {
    try {
      $days = ($now - [datetime]::ParseExact($doc.date, 'yyyy-MM-dd', $null)).TotalDays
      if ($days -lt 0) { $days = 0 }
      $boost = 1.0 + 0.35 * [math]::Exp(-$days / 30.0)
    } catch { }
  }
  $total = $score * $boost
  $scored += [pscustomobject]@{
    total = [math]::Round($total, 3); base = [math]::Round($score, 3); boost = [math]::Round($boost, 2)
    doc = $doc; contrib = @($contrib | Sort-Object part -Descending)
  }
}

if ($scored.Count -eq 0) {
  if ($Json) { '{"query":"' + $Query + '","results":[],"reason":"no-term-match"}' } else { Write-Output ("检索「" + $Query + "」：没有条目包含这些词。") }
  exit 0
}

$ranked = @($scored | Sort-Object total -Descending)
$top = $ranked[0].total
$cut = [math]::Max($Threshold, $top * $Relative)
$kept = @($ranked | Where-Object { $_.total -ge $cut } | Select-Object -First $Max)

if ($kept.Count -eq 0) {
  if ($Json) { '{"query":"' + $Query + '","results":[],"reason":"below-threshold"}' }
  else { Write-Output ("检索「" + $Query + "」：最高分 " + $top + "，低于阈值 " + [math]::Round($Threshold, 2) + "，没有足够匹配的条目。") }
  exit 0
}

if ($Json) {
  $out = foreach ($k in $kept) {
    [pscustomobject]@{
      score  = $k.total
      source = $k.doc.source
      title  = $k.doc.title
      date   = $k.doc.date
      loc    = $k.doc.loc
      terms  = (@($k.contrib | Select-Object -First 4) | ForEach-Object { $_.term }) -join ','
    }
  }
  $out | ConvertTo-Json -Depth 4
  exit 0
}

Write-Output ("检索「" + $Query + "」：共 " + $N + " 份文档参与，命中 " + $kept.Count + " 条（阈值 " + [math]::Round($cut, 2) + "）")
for ($i = 0; $i -lt $kept.Count; $i++) {
  $k = $kept[$i]
  $tag = switch ($k.doc.source) { 'memory' { '情景' } 'facts' { '事实' } 'people' { '画像' } 'diary' { '日记' } default { $k.doc.source } }
  $star = if ($k.doc.stable) { '·稳定' } else { '' }
  Write-Output ("  [" + ($i + 1) + "] " + $k.doc.title + "  〔" + $tag + $star + " · 分 " + $k.total + " · " + $k.doc.loc + "〕")
  # 片段
  $snippet = ''
  foreach ($t in ($k.contrib | ForEach-Object { $_.term })) {
    $idx = $k.doc.body.ToLowerInvariant().IndexOf($t)
    if ($idx -ge 0) {
      $start = [math]::Max(0, $idx - 30)
      $len = [math]::Min(110, $k.doc.body.Length - $start)
      $snippet = ($k.doc.body.Substring($start, $len) -replace '\s+', ' ').Trim()
      break
    }
  }
  if ($snippet) { Write-Output ("      " + $snippet) }
  if ($Explain) {
    $ex = (@($k.contrib | Select-Object -First 4) | ForEach-Object { $_.term + '(' + $_.tfTitle + '标题/' + $_.tfBody + '正文,idf' + $_.idf + ')=' + $_.part }) -join ' + '
    Write-Output ("      [分数构成] " + $ex + "  ×时间加成" + $k.boost)
  }
}
