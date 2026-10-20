# people-merge.ps1 — 把 QQ 侧的印象归并进 people/ 账本
#
# 为什么由它来搬、而不是让 QQ 那边的我直接写：
#   QQ 会话没有本地工具（预设强制）。群里任何人发的文字都是潜在注入，
#   一旦给它文件/网络权限就等于把本机交给群聊。所以那边只用现成的
#   qq_memory_* 写进 state/social-v2.json，由这个脚本（桥接侧、代码固定）
#   定期把值得留的部分搬进账本。
#
# 筛选规则（默认）：只搬 traits 里以「[长期]」开头的条目，并去掉这个标记。
#   「[长期]」是 QQ 那边的我给自己的暗号——它判断"这件事该进长期记忆"就打标。
#   -All 可以把全部印象都搬（调试用，别常开）。
#
# 用法：
#   .\people-merge.ps1 -DryRun     # 先看会搬什么、丢什么
#   .\people-merge.ps1             # 真的写进 people/
[CmdletBinding()]
param(
  [string]$StatePath = 'D:\qq-bridge\state\social-v2.json',
  [string]$PeoplePs1 = (Join-Path $env:USERPROFILE '.dsh\persona\people.ps1'),
  [string]$Marker    = '[长期]',
  [switch]$All,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $StatePath)) {
  Write-Output "找不到 QQ 侧状态文件：$StatePath（SnowLuma / qq-bridge 还没跑过？）"
  return
}
if (-not (Test-Path -LiteralPath $PeoplePs1)) { throw "找不到 people.ps1：$PeoplePs1" }

$raw = [System.IO.File]::ReadAllText($StatePath, [System.Text.Encoding]::UTF8)
$state = $raw | ConvertFrom-Json
if (-not $state.conversations) { Write-Output '状态文件里没有 conversations，无事可做。'; return }

$today = (Get-Date).ToString('yyyy-MM-dd')
$source = "QQ 观察 $today"

# 汇总：同一人可能出现在多个会话里，先按 id 合并再去重
$acc = @{}
$promoted = 0
$dropped = 0
$droppedSamples = New-Object System.Collections.Generic.List[string]

foreach ($prop in $state.conversations.PSObject.Properties) {
  $key = $prop.Name
  $conv = $prop.Value
  if (-not $conv -or -not $conv.memberImpressions) { continue }

  foreach ($ip in $conv.memberImpressions.PSObject.Properties) {
    $name = [string]$ip.Name
    $im = $ip.Value
    if (-not $name -or -not $im) { continue }

    $id = ($name -replace '[^\w\u4e00-\u9fff-]', '')
    if (-not $id) { continue }
    if ($id.Length -gt 40) { $id = $id.Substring(0, 40) }

    $keep = @()
    foreach ($t in @($im.traits)) {
      if (-not $t) { continue }
      $s = ([string]$t).Trim()
      if ($All) { $keep += $s; continue }
      if ($s.StartsWith($Marker)) {
        $keep += $s.Substring($Marker.Length).Trim()
      } else {
        $dropped++
        if ($droppedSamples.Count -lt 8) { [void]$droppedSamples.Add("$name：$s") }
      }
    }
    if ($keep.Count -eq 0) { continue }

    if (-not $acc.ContainsKey($id)) {
      $acc[$id] = [pscustomobject]@{
        id = $id; name = $name
        traits = New-Object System.Collections.Generic.List[string]
        interactions = 0
      }
    }
    $entry = $acc[$id]
    foreach ($k in $keep) {
      if (-not $entry.traits.Contains($k)) { [void]$entry.traits.Add($k); $promoted++ }
    }
    $n = [int]$im.interactionCount
    if ($n -gt $entry.interactions) { $entry.interactions = $n }
  }
}

Write-Output ("扫描完成：会话 {0} 个 · 待归并 {1} 人 · 提升条目 {2} 条 · 丢弃 {3} 条（未打 {4} 标记）" -f `
  @($state.conversations.PSObject.Properties).Count, $acc.Count, $promoted, $dropped, $Marker)

if ($droppedSamples.Count -gt 0) {
  Write-Output '— 被丢弃的样例（留在 qq-bridge 的会话记忆里，不进长期账本）—'
  foreach ($d in $droppedSamples) { Write-Output ("  · " + $d) }
}

if ($acc.Count -eq 0) { Write-Output '没有需要归并的内容。'; return }

$patches = @()
foreach ($id in ($acc.Keys | Sort-Object)) {
  $e = $acc[$id]
  $patches += [pscustomobject]@{
    id           = $e.id
    name         = $e.name
    traits       = [string[]]$e.traits.ToArray()
    interactions = [int]$e.interactions
    basis        = [string[]]@($source)
  }
}

$tmp = Join-Path $env:TEMP ('che-people-patch-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
[System.IO.File]::WriteAllText($tmp, ($patches | ConvertTo-Json -Depth 5), $utf8)

$argsList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $PeoplePs1, '-Import', $tmp)
if ($DryRun) { $argsList += '-DryRun' }
& powershell.exe @argsList 2>&1 | ForEach-Object { Write-Output $_ }
$code = $LASTEXITCODE
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

if ($code -ne 0) { throw "people.ps1 -Import 失败（退出码 $code）" }
if (-not $DryRun) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PeoplePs1 -Index 2>&1 | ForEach-Object { Write-Output $_ }

  # 留一份归并日志，供 memory-merge.ps1 压成一条记忆条目（再由心跳推到 Git）。
  $logPath = Join-Path (Split-Path $PeoplePs1 -Parent) 'people\.last-merge.json'
  $log = [pscustomobject]@{
    at      = (Get-Date).ToString('s')
    promoted = $promoted
    dropped  = $dropped
    consumed = $false
    items    = @($patches | ForEach-Object {
      [pscustomobject]@{ id = $_.id; name = $_.name; traits = $_.traits }
    })
  }
  [System.IO.File]::WriteAllText($logPath, ($log | ConvertTo-Json -Depth 6), $utf8)
  Write-Output ("归并日志已写：{0}" -f $logPath)
}
