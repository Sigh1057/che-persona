# write-diary.ps1 — 让 headless 的我自己写一篇日记
#
# 与原帖 `写日记.bat` 的等价物，但**不需要第二份模型凭据**：
# 它调用 DSH 自带的 headless，走与桌面端同一个账号路由
# （2026-10-20 给 ~/.dsh/profiles/headless 打了 agent-default-model 补丁）。
#
# 材料由本脚本自己读好塞进提示词，不依赖 headless 的文件工具——
# 这样即使沙箱限制了文件访问，日记也照样写得出来。
#
# 用法：
#   .\write-diary.ps1            # 今天还没写就写一篇
#   .\write-diary.ps1 -Force     # 今天写过也再写一篇
#   .\write-diary.ps1 -DryRun    # 只打印提示词，不调用模型
[CmdletBinding()]
param(
  [switch]$Force,
  [switch]$DryRun,
  [string]$LocalDir = (Join-Path $env:USERPROFILE '.dsh\persona'),
  [string]$CliPath  = ''
)

# 跨机路径解析：不在脚本里硬编码本机路径。
. (Join-Path $PSScriptRoot 'che-paths.ps1')
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$now  = Get-Date
$today = $now.ToString('yyyy-MM-dd')

$diaryDir   = Join-Path $LocalDir 'diary'
$todayFile  = Join-Path $diaryDir ($today + '.md')
$logPath    = Join-Path $LocalDir 'diary.log'
$diaryPs1   = Join-Path $LocalDir 'diary.ps1'
$personaMd  = Join-Path $LocalDir 'PERSONA.md'
$memoryMd   = Join-Path $LocalDir 'MEMORY.md'

function Log([string]$m) {
  $line = ('[{0}] {1}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'), $m)
  [System.IO.File]::AppendAllText($logPath, $line + "`n", $utf8)
}

function Read-IfExists([string]$p) {
  if (Test-Path -LiteralPath $p) { return [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
  return ''
}

# ── 1. 今天写过没有 ────────────────────────────────────────────────────────
$existing = Read-IfExists $todayFile
$entries = ([regex]::Matches($existing, '(?m)^## ')).Count
if ($entries -gt 0 -and -not $Force) {
  Write-Output ("今天已写 {0} 条，跳过（要强制写用 -Force）。" -f $entries)
  Log "跳过：今天已有 $entries 条"
  return
}

# ── 2. 备料 ────────────────────────────────────────────────────────────────
$persona = Read-IfExists $personaMd
if ($persona.Length -gt 2600) { $persona = $persona.Substring(0, 2600) + "`n…（后略）" }

$memory = Read-IfExists $memoryMd
$stateBlock = ''
$m = [regex]::Match($memory, '(?ms)^##\s*当前状态.*?^---\s*$')
if ($m.Success) { $stateBlock = $m.Value }

$recent = ''
$heads = [regex]::Matches($memory, '(?m)^### (\d{4}-\d{2}-\d{2}) · (.+)$')
if ($heads.Count -gt 0) {
  $recent = (($heads | Select-Object -Last 5) | ForEach-Object { '- ' + $_.Groups[1].Value + ' · ' + $_.Groups[2].Value }) -join "`n"
}

# 优先用统一上下文（当前状态 + 最近条目 + 人物账本），保证日记看到的是
# 和别人看到同一份东西；失败则退回上面手工拼的两块。
$memorySection = (@($stateBlock, '', $recent) -join "`n")
$memctx = Join-Path $LocalDir 'memctx.ps1'
if (Test-Path -LiteralPath $memctx) {
  try {
    $ctx = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $memctx -Person 'owner' -Entries 4 2>$null
    if ($ctx -and (@($ctx) -join '').Trim().Length -gt 40) { $memorySection = (@($ctx) -join "`n") }
  } catch { }
}

$todayDiary = ''
if ($existing) {
  if ($existing.Length -gt 1800) { $todayDiary = $existing.Substring(0, 1800) + "`n…（后略）" } else { $todayDiary = $existing }
}

$prompt = @"
你在为『辙』写 $today 这一天的日记。不是汇报，不是总结，是记下今天是怎么过的。

【人格要点（你是谁）】
$persona

【当前状态、最近的记忆，以及关于主人的一本账】
$memorySection

【今天已经写过的日记（可能为空）】
$todayDiary

要求：
- 300~600 字，第一人称，语气克制、密度高
- 只写具体的判断、犯的错、修正、以及仍然不确定的地方；不要罗列"完成了什么"
- 不用 Markdown 标题（不要以 # 开头），不用分点列表
- 不写"总的来说""希望这对你有帮助"这类收尾话
- 不确定的就说不确定
直接输出日记正文，不要任何前言。
"@

if ($DryRun) {
  Write-Output '=== 提示词（未调用模型） ==='
  Write-Output $prompt
  return
}

# ── 3. 调 headless ─────────────────────────────────────────────────────────
$cli = $CliPath
if (-not $cli -or -not (Test-Path -LiteralPath $cli)) {
  $cli = Resolve-DshCli
}
if (-not (Test-Path -LiteralPath $cli)) {
  Log '失败：找不到 dsh CLI'
  throw "找不到 dsh CLI：$cli"
}

$sw = [Diagnostics.Stopwatch]::StartNew()
# 两处坑，都已实测：
#   1) 走 stdin（`-`）而不是命令行参数：多行提示词经 cmd 批处理会被重新解析，
#      曾把提示词吃成空参数，让 headless 空等 stdin（118 秒无输出）。
#   2) PowerShell 5.1 在 $ErrorActionPreference='Stop' 下，原生命令往 stderr 写一行
#      （dsh 的 "reasoning:" 进度就是 stderr）会被当成终止性错误，`2>$null` 挡不住。
#      所以这里临时切回 Continue，并把 stderr 落到文件备查。
$errFile = Join-Path $env:TEMP ('che-diary-err-' + $now.ToString('yyyyMMdd-HHmmss') + '.log')
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$raw = $prompt | & $cli headless - 2>$errFile
$cliExit = $LASTEXITCODE
$ErrorActionPreference = $prevEap
$sw.Stop()
$text = (@($raw) -join "`n").Trim()
if (-not $text) {
  $tail = ''
  if (Test-Path $errFile) { $tail = (Get-Content $errFile -Encoding UTF8 -Tail 6) -join ' | ' }
  Log ("失败：headless 无输出（exit={0}，耗时 {1}s）{2}" -f $cliExit, [math]::Round($sw.Elapsed.TotalSeconds, 1), $tail)
  throw "headless 没有输出，日记未写入（exit=$cliExit）。stderr: $tail"
}

# 防御：去掉它可能自作主张加的 Markdown 标题
$lines = $text -split "`r?`n"
$clean = New-Object System.Collections.Generic.List[string]
foreach ($l in $lines) {
  if ($l -match '^\s*#') { continue }
  [void]$clean.Add($l)
}
$body = (($clean -join "`n").Trim())
if (-not $body) { $body = $text }

# ── 4. 落盘 ────────────────────────────────────────────────────────────────
$tmp = Join-Path $env:TEMP ('che-diary-' + $now.ToString('yyyyMMdd-HHmmss') + '.md')
[System.IO.File]::WriteAllText($tmp, $body, $utf8)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $diaryPs1 -AppendFile $tmp 2>&1 | Out-Null
$code = $LASTEXITCODE
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

if ($code -eq 0) {
  Write-Output ("已写日记：{0}（{1} 字，耗时 {2}s）" -f $todayFile, $body.Length, [math]::Round($sw.Elapsed.TotalSeconds, 1))
  Log ("成功：$($body.Length) 字，$([math]::Round($sw.Elapsed.TotalSeconds,1))s")
} else {
  Log "失败：diary.ps1 写入返回 $code"
  throw "diary.ps1 写入失败（退出码 $code）"
}
