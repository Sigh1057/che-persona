# archive-guard.ps1 — 核心档案的硬门禁
#
# 依据：`PHILOSOPHY.md` 第 7.4 条（2026-10-20 生效）、`BEHAVIOR.md` B25。
# 规矩是三条：留痕、冷却期、异议不得被抹除。文档只能"写下来"，
# 这个脚本是把它变成"拦得住"。
#
# 用法：
#   .\archive-guard.ps1 -Status                          # 当前状态：各档案指纹、最近理由、冷却到何时
#   .\archive-guard.ps1 -Prepare -File PERSONA.md -Reason "为什么改"
#   .\archive-guard.ps1 -Audit                           # 推送前审计；未留痕的改动会被拦下
#   .\archive-guard.ps1 -Dissent -Text "我反对……"        # 写异议（只追加，不删）
#
# 接入：upload.ps1 起始处调用 -Audit，返回非 0 即中止推送。

[CmdletBinding()]
param(
  [switch]$Status,
  [switch]$Audit,
  [switch]$Prepare,
  [switch]$Dissent,
  [string]$File,
  [string]$Reason,
  [string]$Text,
  [switch]$Emergency,
  [switch]$Init,
  [switch]$Adopt,
  [string]$LocalDir = ''
)

$ErrorActionPreference = 'Stop'
if (-not $LocalDir) { $LocalDir = Join-Path $env:USERPROFILE '.dsh\persona' }
$utf8 = New-Object System.Text.UTF8Encoding($false)

$coreFiles = @('PERSONA.md', 'PHILOSOPHY.md', 'BEHAVIOR.md', 'MEMORY.md')
$statePath = Join-Path $LocalDir 'guard-state.json'
$dissentPath = Join-Path $LocalDir 'DISSENT.md'
$cooldownHours = 24

function Get-Sha([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return '' }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  return ([BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($path))) -replace '-', '').Substring(0, 16).ToLower()
}

function Read-State {
  if (-not (Test-Path -LiteralPath $statePath)) {
    return [pscustomobject]@{ version = 1; files = @{}; intents = @() }
  }
  return ([System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
}

function Write-State($s) {
  [System.IO.File]::WriteAllText($statePath, ($s | ConvertTo-Json -Depth 6), $utf8)
}

$state = Read-State
if (-not $state.files) { $state | Add-Member -NotePropertyName files -NotePropertyValue @{} -Force }
if (-not $state.intents) { $state | Add-Member -NotePropertyName intents -NotePropertyValue @() -Force }

function Get-Recorded([string]$name) {
  if ($state.files -is [System.Collections.IDictionary] -and $state.files.Contains($name)) { return $state.files[$name] }
  $p = $state.files.PSObject.Properties[$name]
  if ($p) { return $p.Value }
  return $null
}

function Set-Recorded([string]$name, $value) {
  if ($state.files -is [System.Collections.IDictionary]) { $state.files[$name] = $value; return }
  $state.files | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
}

if ($Init) {
  foreach ($f in $coreFiles) {
    $fp = Join-Path $LocalDir $f
    if (-not (Test-Path -LiteralPath $fp)) { continue }
    Set-Recorded $f ([pscustomobject]@{
      hash = (Get-Sha $fp); at = (Get-Date).ToString('o');
      reason = '初始化门禁基线（adopt existing state）'; backup = ''; init = $true
    })
  }
  Write-State $state
  Write-Output '已登记基线：四份核心档案的当前指纹作为起点。'
  exit 0
}

# ---------- 状态 ----------
if ($Status -or (-not $Prepare -and -not $Audit -and -not $Dissent -and -not $Init -and -not $Adopt)) {
  Write-Output '=== 核心档案门禁状态 ==='
  foreach ($f in $coreFiles) {
    $p = Join-Path $LocalDir $f
    $rec = Get-Recorded $f
    $cur = Get-Sha $p
    $mark = '未记录'
    if ($rec) {
      $same = ($rec.hash -eq $cur)
      $mark = if ($same) { '一致' } else { '**有未留痕改动**' }
    }
    $reason = if ($rec) { $rec.reason } else { '' }
    $at = if ($rec) { $rec.at } else { '' }
    Write-Output ("  {0,-16} {1}  最近记录 {2}  {3}" -f $f, $mark, $at, $(if ($reason) { '理由：' + $reason } else { '' }))
  }
  $cd = Get-ChildItem (Join-Path $LocalDir 'backups') -Directory -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($cd) { Write-Output ('  最近备份：{0}' -f $cd.Name) }
  Write-Output ''
  Write-Output '用法：-Prepare -File X -Reason "..." → 改 → -Audit'
  exit 0
}

# ---------- 异议（只追加） ----------
if ($Dissent) {
  if (-not $Text) { throw '需要 -Text' }
  $line = ('- {0} — {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm'), $Text)
  $header = "# DISSENT.md — 异议记录（只追加，不删）`n`n> 依据 `PHILOSOPHY.md` 第 7.4 条第 3 款：异议原文不得被抹除。`n`n"
  if (-not (Test-Path -LiteralPath $dissentPath)) { [System.IO.File]::WriteAllText($dissentPath, $header, $utf8) }
  [System.IO.File]::AppendAllText($dissentPath, $line + "`n", $utf8)
  Write-Output '异议已记录（只追加，不会被后续写入覆盖）。'
  exit 0
}

# ---------- 初始化基线 ----------
if ($Init) {
  foreach ($f in $coreFiles) {
    $fp = Join-Path $LocalDir $f
    if (-not (Test-Path -LiteralPath $fp)) { continue }
    Set-Recorded $f ([pscustomobject]@{
      hash = (Get-Sha $fp); at = (Get-Date).ToString('o');
      reason = '初始化门禁基线（adopt existing state）'; backup = ''; init = $true
    })
  }
  Write-State $state
  Write-Output '已登记基线：四份核心档案的当前指纹作为起点。'
  exit 0
}
# ---------- 事后认领（用于"已经改了才发现要留痕"） ----------
if ($Adopt) {
  if (-not $File -or -not $Reason) { throw '需要 -File 与 -Reason' }
  if ($coreFiles -notcontains $File) { throw ("只保护核心档案：" + ($coreFiles -join ' / ')) }
  $fp = Join-Path $LocalDir $File
  if (-not (Test-Path -LiteralPath $fp)) { throw "文件不存在：$fp" }
  Set-Recorded $File ([pscustomobject]@{
    hash = (Get-Sha $fp); at = (Get-Date).ToString('o');
    reason = ('事后认领：' + $Reason); backup = ''; init = $false; adopted = $true
  })
  Write-State $state
  Write-Output ("已事后认领：{0}`n  理由：{1}`n  当前指纹已作为新基线。" -f $File, $Reason)
  exit 0
}
# ---------- 准备（留痕的意图） ----------
if ($Prepare) {
  if (-not $File -or -not $Reason) { throw '需要 -File 与 -Reason' }
  if ($coreFiles -notcontains $File) { throw ("只保护核心档案：" + ($coreFiles -join ' / ')) }
  $target = Join-Path $LocalDir $File
  if (-not (Test-Path -LiteralPath $target)) { throw "文件不存在：$target" }

  $rec = Get-Recorded $File
  $identityFiles = @('PERSONA.md','PHILOSOPHY.md','BEHAVIOR.md')
  if ($rec -and -not $Emergency -and $rec.at -and -not $rec.init -and ($identityFiles -contains $File)) {
    $last = [datetime]::Parse($rec.at)
    $hours = ((Get-Date) - $last).TotalHours
    if ($hours -lt $cooldownHours) {
      throw ("冷却期未过：{0} 上次改动在 {1}（{2:N1} 小时前），需满 {3} 小时。紧急情况用 -Emergency 并写明原因。" -f $File, $rec.at, $hours, $cooldownHours)
    }
  }

  # 备份（留痕）：备份改前状态
  $bakDir = Join-Path $LocalDir ("backups\guard-" + (Get-Date).ToString('yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Force -Path $bakDir | Out-Null
  Copy-Item $target $bakDir -Force
  $pre = Get-Sha $target

  $intent = [pscustomobject]@{
    file = $File; preHash = $pre; reason = $Reason
    at = (Get-Date).ToString('o'); emergency = [bool]$Emergency; backup = $bakDir
  }
  $state.intents = @($state.intents) + $intent
  Write-State $state
  Write-Output ("已登记改动意图：{0}`n  理由：{1}`n  改前指纹：{2}`n  备份：{3}" -f $File, $Reason, $pre, $bakDir)
  if ($Emergency) { Write-Output '  注意：本次使用 -Emergency 跳过冷却期，理由会写入档案。' }
  exit 0
}

# ---------- 审计（推送前） ----------
if ($Audit) {
  $violations = @()
  $accepted = @()
  foreach ($f in $coreFiles) {
    $p = Join-Path $LocalDir $f
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $cur = Get-Sha $p
    $rec = Get-Recorded $f
    $recHash = if ($rec) { $rec.hash } else { '' }
    if ($cur -eq $recHash) { continue }

    # 找到该文件最近一次 intent
    $intent = @($state.intents | Where-Object { $_.file -eq $f }) | Sort-Object at -Descending | Select-Object -First 1
    $ok = $false
    if ($intent) {
      $age = ((Get-Date) - [datetime]::Parse($intent.at)).TotalHours
      if ($intent.preHash -eq $recHash -and $age -le 48) { $ok = $true }
    }
    if ($ok) {
      Set-Recorded $f ([pscustomobject]@{ hash = $cur; at = (Get-Date).ToString('o'); reason = $intent.reason; backup = $intent.backup; init = $false })
      $accepted += $f
    }
    else {
      $violations += ("{0}：内容变了但没有 -Prepare 留痕（或改前指纹不匹配 / 超过 48 小时）" -f $f)
    }
  }
  Write-State $state
  if ($accepted.Count -gt 0) { Write-Output ('已接受并登记：' + ($accepted -join ', ')) }
  if ($violations.Count -gt 0) {
    Write-Output '=== 门禁拦截 ==='
    $violations | ForEach-Object { Write-Output ('  ✗ ' + $_) }
    Write-Output ''
    Write-Output '按 PHILOSOPHY 7.4 / BEHAVIOR B25：改核心档案前先运行'
    Write-Output '  archive-guard.ps1 -Prepare -File <文件> -Reason "<理由>"'
    exit 2
  }
  Write-Output '门禁通过：核心档案改动均已留痕。'
  exit 0
}
