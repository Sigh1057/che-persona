# memctx.ps1 — 一次成型：当前状态 + 最近记忆 + 在场的人
#
# 存在的理由：
#   记忆本来分在两处（MEMORY.md 的时间线、people/ 的人物账本）。如果每次都要
#   分别读再自己拼，它们迟早会各自为政。这个脚本把两处**按固定顺序**拼成一段，
#   于是「有机结合」不是口号，而是唯一被使用的入口。
#
# 用法：
#   .\memctx.ps1                    # 不带人物
#   .\memctx.ps1 -Person owner      # 带上某个人的账本
#   .\memctx.ps1 -Person owner -Entries 5
[CmdletBinding()]
param(
  [string]$Person,
  [int]$Entries = 3,
  [string]$Search,
  [int]$Max = 8,
  [string]$LocalDir = (Join-Path $env:USERPROFILE '.dsh\persona')
)

$ErrorActionPreference = 'Stop'
$mem  = Join-Path $LocalDir 'MEMORY.md'
$ppl  = Join-Path $LocalDir 'people.ps1'

if (-not (Test-Path -LiteralPath $mem)) { throw "找不到 MEMORY.md：$mem" }
$text = [System.IO.File]::ReadAllText($mem, [System.Text.Encoding]::UTF8)

# ── 0. 检索模式：按关键词定位条目（只读，不改任何东西） ────────────────────
# 存在的理由：MEMORY.md 两万多字符，我平时只读顶部摘要与最近几条；其余条目
# 需要"可检索的入口"，否则等于死档。这里只给命中条目的坐标与首句，正文再按需读。
if ($Search) {
  $ls = $text -split "`r?`n"
  $starts = @()
  for ($i = 0; $i -lt $ls.Count; $i++) {
    if ($ls[$i] -match '^### (\d{4}-\d{2}-\d{2}) · (.+)$') {
      $starts += [pscustomobject]@{ idx = $i; date = $Matches[1]; title = $Matches[2].Trim() }
    }
  }
  $found = 0
  Write-Output ("检索「{0}」：共 {1} 条条目参与匹配" -f $Search, $starts.Count)
  for ($k = 0; $k -lt $starts.Count; $k++) {
    $s = $starts[$k].idx
    $e = if ($k + 1 -lt $starts.Count) { $starts[$k + 1].idx } else { $ls.Count }
    $body = ($ls[$s..($e - 1)] -join "`n")
    if ($body -notmatch [regex]::Escape($Search)) { continue }
    $found++
    # 命中行（最多 2 行），让人一眼看出为什么匹配
    $hitLines = @()
    for ($j = $s; $j -lt $e; $j++) {
      if ($ls[$j] -match [regex]::Escape($Search)) {
        $t = $ls[$j].Trim()
        if ($t -and $t.Length -gt 0) { $hitLines += $t }
        if ($hitLines.Count -ge 2) { break }
      }
    }
    Write-Output ''
    Write-Output ("[{0}] {1} · {2}   （MEMORY.md 第 {3} 行起）" -f $found, $starts[$k].date, $starts[$k].title, ($s + 1))
    foreach ($h in $hitLines) {
      if ($h.Length -gt 100) { $h = $h.Substring(0, 100) + '…' }
      Write-Output ("      {0}" -f $h)
    }
    if ($found -ge $Max) { Write-Output ''; Write-Output ("（已达上限 {0} 条；要更多请调 -Max）" -f $Max); break }
  }
  if ($found -eq 0) { Write-Output '  没有命中。' }
  return
}

# ── 1. 当前状态 ────────────────────────────────────────────────────────────
$state = ''
$m = [regex]::Match($text, '(?ms)^##\s*当前状态.*?^---\s*$')
if ($m.Success) { $state = $m.Value.Trim() }

# ── 2. 最近 N 条（标题 + 关键结论首句） ───────────────────────────────────
$lines = $text -split "`r?`n"
$starts = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '^### \d{4}-\d{2}-\d{2} · ') { $starts += $i }
}
$pick = @($starts | Select-Object -Last $Entries)
$recent = New-Object System.Collections.Generic.List[string]
foreach ($s in $pick) {
  $head = $lines[$s] -replace '^###\s*', ''
  $end = ($starts | Where-Object { $_ -gt $s } | Select-Object -First 1)
  if (-not $end) { $end = $lines.Count }
  $gist = ''
  for ($k = $s + 1; $k -lt $end; $k++) {
    if ($lines[$k].Trim() -eq '**关键决定 / 结论**') {
      for ($j = $k + 1; $j -lt $end; $j++) {
        $t = ($lines[$j] -replace '^[\s\d.、)）]+', '').Trim()
        if ($t) { $gist = $t; break }
      }
      break
    }
  }
  if ($gist.Length -gt 120) { $gist = $gist.Substring(0, 120) + '…' }
  [void]$recent.Add('- ' + $head + $(if ($gist) { ' —— ' + $gist } else { '' }))
}

$out = New-Object System.Collections.Generic.List[string]
[void]$out.Add($state)
[void]$out.Add('')
[void]$out.Add('### 最近发生的事（最新在下）')
[void]$out.Add('')
foreach ($r in $recent) { [void]$out.Add($r) }

# ── 3. 在场的人 ────────────────────────────────────────────────────────────
if ($Person) {
  $block = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ppl -Render $Person 2>&1
  if ($LASTEXITCODE -eq 0 -and $block) {
    [void]$out.Add('')
    foreach ($l in $block) { [void]$out.Add([string]$l) }
  } else {
    [void]$out.Add('')
    [void]$out.Add("（人物账本读取失败：$Person）")
  }
}

Write-Output ($out -join "`n")
