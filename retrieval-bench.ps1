# retrieval-bench.ps1 — 记忆检索的回归测试
#
# 为什么需要它：检索质量靠"感觉"是调不出来的。每次改打分逻辑，都要跑同一组
# 有标准答案的查询，看是变好还是变坏——这是从 dsh-bigfish（151 项单测）和
# MaiBot（调参中心）学来的做法：把判断固化成可重复的实验。
#
# 用法：
#   .\retrieval-bench.ps1              # 跑全部用例
#   .\retrieval-bench.ps1 -Verbose2    # 打印每条查询的完整输出
#   .\retrieval-bench.ps1 -Json        # 机器可读
#
# 退出码：0 = 全部符合预期；1 = 有不符合。

[CmdletBinding()]
param(
  [switch]$Verbose2,
  [switch]$Json,
  [string]$LocalDir = ''
)

$ErrorActionPreference = 'Stop'
if (-not $LocalDir) { $LocalDir = Join-Path $env:USERPROFILE '.dsh\persona' }
$engine = Join-Path $PSScriptRoot 'memsearch.ps1'
if (-not (Test-Path -LiteralPath $engine)) { throw "找不到 memsearch.ps1：$engine" }

# 用例：Expect 为空字符串表示"应当没有足够匹配"；info=$true 只观察不计分。
# 「她怎么记住我是谁」单列观察项：字面检索只能抓「记住」这种实词，给不出语义答案，
# 但也不该假装给了——这条记录的是能力边界，不是失败。
$cases = @(
  @{ q = '生日';               expect = '生日';        note = '直接词' },
  @{ q = '密钥';               expect = '密钥泄露';    note = '同义词：条目里写的是密钥' },
  @{ q = '401';                expect = '401 关闭';    note = '代码型词，应命中标题' },
  @{ q = 'che-private';        expect = '私密档案';    note = '英文仓库名' },
  @{ q = 'SnowLuma';           expect = 'qq-bridge';   note = '实体名' },
  @{ q = '脱敏';               expect = '私密档案';    note = '关键词' },
  @{ q = '名字';               expect = '名字的决定';  note = '同义词：名字↔称呼↔命名' },
  @{ q = '人格 v4';            expect = '人格 v4';     note = '短语' },
  @{ q = '看门狗';             expect = '';           note = '未实现，应明说没有' },
  @{ q = '股票行情';           expect = '';           note = '噪声：库里不存在的主题，应拒绝' },
  @{ q = '她怎么记住我是谁';   expect = '';           note = '纯语义（只观察，不计分）'; info = $true }
)

$results = @()
foreach ($c in $cases) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -Query $c.q -Max 3 2>&1
  $sw.Stop()
  $lines = @($out | ForEach-Object { [string]$_ })
  $titles = @($lines | Where-Object { $_ -match '^\s*\[\d\]\s' } | ForEach-Object { ($_ -replace '^\s*\[\d\]\s+', '').Trim() })
  $empty = ($titles.Count -eq 0)
  $top1 = if ($titles.Count -gt 0) { $titles[0] } else { '' }

  if ($c.expect -eq '') {
    $ok = $empty
    $verdict = if ($ok) { '正确（明说没有）' } else { "不符合（返回了 $($titles.Count) 条）" }
  }
  else {
    $ok = ($titles -join ' | ') -like "*$($c.expect)*"
    $verdict = if ($ok) { '命中' } else { '未命中' }
  }

  $results += [pscustomobject]@{
    query = $c.q; expect = $c.expect; ok = $ok; verdict = $verdict
    ms = $sw.ElapsedMilliseconds; top1 = $top1; note = $c.note; info = [bool]$c.info
  }
  if ($Verbose2) {
    Write-Output ('--- ' + $c.q + ' (' + $c.note + ') ---')
    $lines | ForEach-Object { Write-Output ('    ' + $_) }
  }
}

$scored = @($results | Where-Object { -not $_.info })
$infoRows = @($results | Where-Object { $_.info })
$pass = @($scored | Where-Object { $_.ok }).Count
$total = $scored.Count
if ($Json) {
  [pscustomobject]@{ pass = $pass; total = $total; cases = $results } | ConvertTo-Json -Depth 5
}
else {
  $scored | Select-Object query, expect, verdict, ms, note | Format-Table -AutoSize -Wrap | Out-String -Width 160 | Write-Output
  $avg = [math]::Round((($scored | Measure-Object ms -Average).Average), 0)
  Write-Output ("检索评测：{0} / {1} 通过，平均 {2} ms" -f $pass, $total, $avg)
  foreach ($r in $scored) {
    if (-not $r.ok) { Write-Output ("  不符合：{0}（期望 {1}，首条 {2}）" -f $r.query, $r.expect, $r.top1) }
  }
  foreach ($r in $infoRows) {
    $state = if ($r.top1) { '返回：' + $r.top1 } else { '明说没有' }
    Write-Output ("  观察项：{0} → {1}" -f $r.query, $state)
  }
}

if ($pass -eq $total) { exit 0 } else { exit 1 }
