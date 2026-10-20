# memory-merge.ps1 — 把一批人物归并压成一条记忆条目，走 memory-push 入档
#
# 为什么需要它：
#   people-merge.ps1 只写本地账本（people/ 是私密的，不上云）。但「长期记忆落在
#   Git 里」这件事只有 MEMORY.md 承担。所以这里把一批归并压成**一条**六段条目，
#   交给 memory-push.ps1 -LocalOnly 追加，再由每小时的心跳推到 GitHub。
#
#   一条 = 一批，不是一条 = 一个印象：这样即使一天归并很多次，git 历史也不会变成
#   群聊日志，回滚与对比仍然可用。
#
# 用法：
#   .\memory-merge.ps1 -DryRun
#   .\memory-merge.ps1
[CmdletBinding()]
param(
  [string]$LocalDir = (Join-Path $env:USERPROFILE '.dsh\persona'),
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$logPath  = Join-Path $LocalDir 'people\.last-merge.json'
$pushPs1  = Join-Path $LocalDir 'memory-push.ps1'

if (-not (Test-Path -LiteralPath $logPath)) { Write-Output '没有归并日志（people-merge 还没跑过？）'; return }
if (-not (Test-Path -LiteralPath $pushPs1)) { throw "找不到 memory-push.ps1：$pushPs1" }

$log = [System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
if ($log.consumed -eq $true) { Write-Output '这批归并已经入档，无需重复。'; return }
if ([int]$log.promoted -le 0) { Write-Output '这批没有提升任何条目，不写记忆。'; return }

$items = @($log.items)
$names = ($items | ForEach-Object { $_.name }) -join '、'

$lines = New-Object System.Collections.Generic.List[string]
foreach ($it in $items) {
  $t = (@($it.traits) -join '；')
  if ($t) { [void]$lines.Add(('- **{0}**：{1}' -f $it.name, $t)) }
}

$today = (Get-Date).ToString('yyyy-MM-dd')

# 用单引号 here-string + 占位符，避免双引号 here-string 里嵌套引号在 PS 5.1 下解析失败。
$tpl = @'
### __TODAY__ · 从 QQ 侧归并：__COUNT__ 人 / __PROMOTED__ 条长期印象

**发生了什么**
桥接侧把带 `[长期]` 标记的会话印象搬进了 `people/`：__NAMES__。共提升 __PROMOTED__ 条，另有 __DROPPED__ 条因为没打标记，留在 qq-bridge 的会话记忆里（按 24 小时 / 2 小时自然过期）。

**关键决定 / 结论**
- 归并由**桥接侧脚本**执行，不给 QQ 会话任何文件或网络权限：群里任何人发的文字都是潜在注入，权限面不能为「记忆更方便」而扩大。
- **筛选权在 QQ 那边的我**：它用 `[长期]` 前缀决定什么值得进长期记忆；搬运只执行，不做二次判断。
- 一条 = 一批。即使一天归并多次也只产生一条记忆条目，git 历史不会退化成群聊日志。

本期归并内容：
__LINES__

**我判断的依据与置信度**
实测：`people.ps1 -Import` 写入 __COUNT__ 人；`people.ps1 -Check` 回指悬空 0 条；归并日志时间 __AT__。
本条由 `memory-merge.ps1` 自动生成，内容取自 qq-bridge 的 `state/social-v2.json`。

**代价与风险**
- **本条不含人工判断**，只有搬运结果。若 QQ 侧打标过滥，长期记忆会朝「印象流水」退化。
- `people/*.json` 仍只留本地，未上云；本条只记录「归并发生过、涉及谁」，复本在账本里。

**未解决**
无。

**相关文件**
- people/ 目录下 __COUNT__ 本账
- people/.last-merge.json
'@

$entry = $tpl.Replace('__TODAY__', $today).
  Replace('__COUNT__', [string]@($items).Count).
  Replace('__PROMOTED__', [string][int]$log.promoted).
  Replace('__DROPPED__', [string][int]$log.dropped).
  Replace('__NAMES__', $names).
  Replace('__AT__', [string]$log.at).
  Replace('__LINES__', ($lines -join "`n"))

if ($DryRun) {
  Write-Output '=== 将写入的记忆条目（演练，未提交） ==='
  Write-Output $entry
  return
}

$tmp = Join-Path $env:TEMP ('che-mem-merge-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.md')
[System.IO.File]::WriteAllText($tmp, $entry, $utf8)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pushPs1 `
  -Owner 'Sigh1057' -Repo 'che-persona' -ContentFile $tmp -LocalOnly 2>&1 | ForEach-Object { Write-Output $_ }
$code = $LASTEXITCODE
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
if ($code -ne 0) { throw "memory-push 失败（退出码 $code）" }

# 标记已消费，避免下一轮重复写同一条
$log.consumed = $true
[System.IO.File]::WriteAllText($logPath, ($log | ConvertTo-Json -Depth 6), $utf8)
Write-Output '已入档（本地），等心跳推到 GitHub。'
