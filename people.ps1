# people.ps1 — 人物账本
#
# 为什么需要它：
#   MEMORY.md 是一根时间线——我知道「今天发生了什么」，但不知道「这个人是谁、
#   我怎么看他、我们之间有什么没说完的话」。而聊天的主体是人。
#
# 为什么不另起一摊（有机结合的三条约定）：
#   1. **只读一侧、写另一侧**：MEMORY.md 仍然只由 memory-push.ps1 追加，
#      本脚本**从不写 MEMORY.md**；人物账本里的每条都靠 `basis` 回指条目
#      （形如 "2026-10-20 · 标题"），-Check 会校验指向的条目真的存在，防悬空。
#   2. **同一种摘要格式**：-Render 输出的块与 sync-role 的记忆摘要同风格，
#      拼在一起就是一段上下文，而不是两份互不相干的人格。
#   3. **同一套淘汰规则**：重复的内容挪到最新而不是再存一条（这点学的是
#      ai-companion 的 Memory：他说过十次的事，账上只有一条，但排最前）。
#
# 用法：
#   .\people.ps1                                  # 列人名单
#   .\people.ps1 -List                            # 同上，带一句话概括
#   .\people.ps1 -Show owner                      # 渲染成 Markdown 给人看
#   .\people.ps1 -Render owner                    # 渲染成注入用上下文（给模型看）
#   .\people.ps1 -Index                           # 重建 people\INDEX.md
#   .\people.ps1 -Check                           # 校验所有 basis 指向的条目是否存在
#   .\people.ps1 -Remember owner -Trait "讨厌空洞鼓励" -Basis "2026-10-20 · 某条目"
[CmdletBinding()]
param(
  [switch]$List,
  [switch]$Index,
  [switch]$Check,
  [string]$Show,
  [string]$Render,
  [string]$Remember,
  [string]$Import,
  [switch]$DryRun,
  [string]$Name,
  [string[]]$Trait,
  [string[]]$Fact,
  [string[]]$Topic,
  [string[]]$Pending,
  [string[]]$Basis,
  [switch]$Touched,
  [string]$Dir = (Join-Path $env:USERPROFILE '.dsh\persona\people'),
  [string]$MemoryPath = (Join-Path $env:USERPROFILE '.dsh\persona\MEMORY.md')
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }

$CAP = @{ traits = 40; facts = 60; topics = 20; pending = 12; basis = 40 }
$MAXLEN = 160

function PersonFile([string]$id) { Join-Path $Dir ($id + '.json') }

function Read-Person([string]$id) {
  $f = PersonFile $id
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  $raw = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
  $o = $raw | ConvertFrom-Json
  foreach ($k in @('traits','facts','topics','pending','basis')) {
    if (-not (@($o.PSObject.Properties.Name) -contains $k)) {
      $o | Add-Member -NotePropertyName $k -NotePropertyValue @() -Force
    }
  }
  return $o
}

function Save-Person($o) {
  $json = $o | ConvertTo-Json -Depth 6
  [System.IO.File]::WriteAllText((PersonFile $o.id), $json, $utf8)
}

function Get-PersonIds {
  Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File |
    Where-Object { $_.BaseName -ne 'INDEX' -and -not $_.BaseName.StartsWith('.') } |
    ForEach-Object { $_.BaseName } | Sort-Object
}

# 去重挪最新 + 截断 + 施加上限
function Add-Points([object]$arr, [string[]]$values, [int]$cap) {
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($v in @($arr)) { if ($v) { [void]$list.Add([string]$v) } }
  foreach ($v in @($values)) {
    if ([string]::IsNullOrWhiteSpace($v)) { continue }
    $s = ($v -replace '\s+', ' ').Trim()
    if ($s.Length -gt $MAXLEN) { $s = $s.Substring(0, $MAXLEN) }
    $idx = $list.IndexOf($s)
    if ($idx -ge 0) { $list.RemoveAt($idx) }   # 提过的挪到最新，不重复堆叠
    [void]$list.Add($s)
  }
  while ($list.Count -gt $cap) { $list.RemoveAt(0) }
  return ,([string[]]$list.ToArray())
}

# ── 写入 ────────────────────────────────────────────────────────────────────
if ($Remember) {
  $id = $Remember.Trim()
  if ($id -notmatch '^[\w\u4e00-\u9fff-]{1,40}$') { throw "id 只允许字母数字下划线中文与短横：$id" }
  $o = Read-Person $id
  if (-not $o) {
    $o = [pscustomobject]@{
      id = $id; name = ($(if ($Name) { $Name } else { $id }))
      traits = @(); facts = @(); topics = @(); pending = @(); basis = @()
      interactions = 0
      firstSeenAt = (Get-Date).ToString('yyyy-MM-dd')
      lastSeenAt  = (Get-Date).ToString('yyyy-MM-dd')
    }
  }
  if ($Name) { $o.name = $Name.Trim() }
  if ($Trait)   { $o.traits  = Add-Points $o.traits  $Trait   $CAP.traits }
  if ($Fact)    { $o.facts   = Add-Points $o.facts   $Fact    $CAP.facts }
  if ($Topic)   { $o.topics  = Add-Points $o.topics  $Topic   $CAP.topics }
  if ($Pending) { $o.pending = Add-Points $o.pending $Pending $CAP.pending }
  if ($Basis)   { $o.basis   = Add-Points $o.basis   $Basis   $CAP.basis }
  if ($Touched) { $o.interactions = ([int]$o.interactions) + 1 }
  $o.lastSeenAt = (Get-Date).ToString('yyyy-MM-dd')
  Save-Person $o
  Write-Output ("已更新 {0}（traits {1} / facts {2} / topics {3} / pending {4} / basis {5}）" -f `
    $o.id, @($o.traits).Count, @($o.facts).Count, @($o.topics).Count, @($o.pending).Count, @($o.basis).Count)
  return
}

# ── 批量导入（由合并脚本 people-merge.ps1 调用） ──────────────────────────
# 传入 JSON 数组：[{ id, name, traits[], facts[], topics[], pending[], basis[], interactions }]
# 仍然走同一套 Add-Points（去重挪最新 + 截断 + 上限），所以批量导入不会绕过规则。
if ($Import) {
  if (-not (Test-Path -LiteralPath $Import)) { throw "找不到导入文件：$Import" }
  $rawJson = [System.IO.File]::ReadAllText($Import, [System.Text.Encoding]::UTF8)
  # 注意：PS 5.1 里 `$x | ConvertFrom-Json` 会把 JSON 数组整个当成**一个对象**
  # 返回；若再套 @() 包一层，foreach 只迭代一次、$p.id 会被拼成 "a b"。
  # 所以这里直接赋值，不套 @()，也不走管道。
  $patches = $rawJson | ConvertFrom-Json
  if (-not $patches) { Write-Output '导入文件为空，无事可做。'; return }
  $changed = 0
  foreach ($p in $patches) {
    $id = ([string]$p.id).Trim()
    if (-not $id -or $id -notmatch '^[\w\u4e00-\u9fff-]{1,40}$') {
      Write-Output ("  跳过非法 id：{0}" -f $p.id); continue
    }
    $o = Read-Person $id
    if (-not $o) {
      $o = [pscustomobject]@{
        id = $id; name = ($(if ($p.name) { [string]$p.name } else { $id }))
        traits = @(); facts = @(); topics = @(); pending = @(); basis = @()
        interactions = 0
        firstSeenAt = (Get-Date).ToString('yyyy-MM-dd')
        lastSeenAt  = (Get-Date).ToString('yyyy-MM-dd')
      }
    }
    if ($p.name) { $o.name = ([string]$p.name).Trim() }
    if ($p.traits)  { $o.traits  = Add-Points $o.traits  @($p.traits)  $CAP.traits }
    if ($p.facts)   { $o.facts   = Add-Points $o.facts   @($p.facts)   $CAP.facts }
    if ($p.topics)  { $o.topics  = Add-Points $o.topics  @($p.topics)  $CAP.topics }
    if ($p.pending) { $o.pending = Add-Points $o.pending @($p.pending) $CAP.pending }
    if ($p.basis)   { $o.basis   = Add-Points $o.basis   @($p.basis)   $CAP.basis }
    if ($null -ne $p.interactions) {
      $n = [int]$p.interactions
      if ($n -gt [int]$o.interactions) { $o.interactions = $n }   # 取较大值，避免每次归并重复累加
    }
    $o.lastSeenAt = (Get-Date).ToString('yyyy-MM-dd')
    if ($DryRun) {
      Write-Output ("  [演练] 将更新 {0}（traits {1} / facts {2} / topics {3} / pending {4}）" -f `
        $o.id, @($o.traits).Count, @($o.facts).Count, @($o.topics).Count, @($o.pending).Count)
    } else {
      Save-Person $o
      $changed++
      Write-Output ("  已更新 {0}（traits {1} / facts {2} / topics {3} / pending {4}）" -f `
        $o.id, @($o.traits).Count, @($o.facts).Count, @($o.topics).Count, @($o.pending).Count)
    }
  }
  if ($DryRun) { Write-Output '演练结束，未写入任何文件。' } else { Write-Output ("导入完成，{0} 人受影响。" -f $changed) }
  return
}

# ── 渲染（给人看） ──────────────────────────────────────────────────────────
function Format-Person($o) {
  $L = New-Object System.Collections.Generic.List[string]
  [void]$L.Add("# $($o.name)（$($o.id)）")
  [void]$L.Add('')
  [void]$L.Add("- **首次**：$($o.firstSeenAt)　**最近**：$($o.lastSeenAt)　**互动**：$($o.interactions)")
  [void]$L.Add('')
  $sec = @(
    @{ key='traits';  title='我记得的他（性格/习惯）' }
    @{ key='facts';   title='他告诉过我的事实' }
    @{ key='topics';  title='聊过的话题' }
    @{ key='pending'; title='我心里还记着没说出口的' }
    @{ key='basis';   title='依据（指向 MEMORY.md 条目）' }
  )
  foreach ($s in $sec) {
    $items = @($o.($s.key))
    [void]$L.Add("## $($s.title)")
    [void]$L.Add('')
    if ($items.Count -eq 0) { [void]$L.Add('（无）') }
    else { foreach ($i in $items) { [void]$L.Add("- $i") } }
    [void]$L.Add('')
  }
  return ($L -join "`n")
}

if ($Show) {
  $o = Read-Person $Show
  if (-not $o) { throw "没有这个人：$Show" }
  Write-Output (Format-Person $o)
  return
}

# ── 渲染（给模型看，与记忆摘要同风格） ─────────────────────────────────────
if ($Render) {
  $o = Read-Person $Render
  if (-not $o) { throw "没有这个人：$Render" }
  $L = New-Object System.Collections.Generic.List[string]
  [void]$L.Add("### 关于 $($o.name)（$($o.id)）的一本账")
  [void]$L.Add('')
  if (@($o.traits).Count)  { [void]$L.Add('**我记得的他**：' + ((@($o.traits) | Select-Object -Last 12) -join '；')) }
  if (@($o.facts).Count)   { [void]$L.Add('**他告诉过我**：' + ((@($o.facts) | Select-Object -Last 12) -join '；')) }
  if (@($o.topics).Count)  { [void]$L.Add('**聊过**：' + ((@($o.topics) | Select-Object -Last 8) -join '；')) }
  if (@($o.pending).Count) { [void]$L.Add('**我还没说出口的**：' + ((@($o.pending) | Select-Object -Last 4) -join '；')) }
  if ($o.interactions)     { [void]$L.Add("**互动**：$($o.interactions) 次，最近 $($o.lastSeenAt)") }
  if (@($o.basis).Count)   { [void]$L.Add('**依据**：' + ((@($o.basis) | Select-Object -Last 6) -join '；')) }
  [void]$L.Add('')
  Write-Output ($L -join "`n")
  return
}

# ── 校验 basis 是否悬空 ────────────────────────────────────────────────────
if ($Check) {
  if (-not (Test-Path -LiteralPath $MemoryPath)) { throw "找不到 MEMORY.md：$MemoryPath" }
  $mem = [System.IO.File]::ReadAllText($MemoryPath, [System.Text.Encoding]::UTF8)
  $titles = @{}
  foreach ($m in [regex]::Matches($mem, '(?m)^### (\d{4}-\d{2}-\d{2}) · (.+)$')) {
    $titles[($m.Groups[1].Value + ' · ' + $m.Groups[2].Value.Trim())] = $true
  }
  $bad = 0; $total = 0
  foreach ($id in (Get-PersonIds)) {
    $o = Read-Person $id
    foreach ($b in @($o.basis)) {
      # 只校验「日期 · 标题」形式的回指；来自 QQ 侧观察的来源标记（如
      # 「QQ 群聊 2026-10-20」）本来就不指向 MEMORY 条目，跳过不算悬空。
      if ($b -notmatch '^\d{4}-\d{2}-\d{2} · ') { continue }
      $total++
      if (-not $titles.ContainsKey($b)) { $bad++; Write-Output ("  悬空  {0} → 「{1}」在 MEMORY.md 里找不到" -f $id, $b) }
    }
  }
  Write-Output ("basis 回指共 {0} 条，悬空 {1} 条。" -f $total, $bad)
  if ($bad -gt 0) { exit 1 }
  return
}

# ── 重建 INDEX.md ──────────────────────────────────────────────────────────
if ($Index) {
  $rows = New-Object System.Collections.Generic.List[string]
  [void]$rows.Add('# INDEX — 人名单')
  [void]$rows.Add('')
  [void]$rows.Add('> 由 `people.ps1 -Index` 生成。一人一行，最近见面在上。')
  [void]$rows.Add('')
  [void]$rows.Add('| 人 | 称呼 | 最近 | 互动 | 一句话 |')
  [void]$rows.Add('|---|---|---|---|---|')
  $all = @()
  foreach ($id in (Get-PersonIds)) { $all += (Read-Person $id) }
  foreach ($o in ($all | Sort-Object lastSeenAt -Descending)) {
    $brief = ''
    if (@($o.traits).Count) { $brief = (@($o.traits) | Select-Object -Last 1) }
    elseif (@($o.facts).Count) { $brief = (@($o.facts) | Select-Object -Last 1) }
    if ($brief.Length -gt 40) { $brief = $brief.Substring(0, 40) + '…' }
    [void]$rows.Add(('| `{0}` | {1} | {2} | {3} | {4} |' -f $o.id, $o.name, $o.lastSeenAt, $o.interactions, $brief))
  }
  [System.IO.File]::WriteAllText((Join-Path $Dir 'INDEX.md'), (($rows -join "`n") + "`n"), $utf8)
  Write-Output ("已重建索引：{0} 人 → {1}" -f @($all).Count, (Join-Path $Dir 'INDEX.md'))
  return
}

# ── 默认 / -List ───────────────────────────────────────────────────────────
$ids = @(Get-PersonIds)
if ($ids.Count -eq 0) { Write-Output "还没有人。目录：$Dir"; return }
Write-Output ("共 {0} 人，目录：{1}" -f $ids.Count, $Dir)
foreach ($id in $ids) {
  $o = Read-Person $id
  $brief = ''
  if (@($o.traits).Count) { $brief = (@($o.traits) | Select-Object -Last 1) }
  if ($List -and $brief.Length -gt 50) { $brief = $brief.Substring(0, 50) + '…' }
  if ($List) { Write-Output ("  {0,-12} {1,-10} 最近 {2}  互动 {3}  {4}" -f $o.id, $o.name, $o.lastSeenAt, $o.interactions, $brief) }
  else { Write-Output ("  {0,-12} {1}" -f $o.id, $o.name) }
}
