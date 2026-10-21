# doctor.ps1 — 辙的身体体检
#
# 检查项：
#   1. 本地镜像完整性（文件是否齐全、MEMORY.md 条目数）
#   2. 凭据可用性（token 能否认证、scope 是否够）
#   3. 远端可达性与一致性（本地与远端 MEMORY.md 是否同步）
#   4. 技能挂载状态（che-recall 是否被发现）
#
# 用法：
#   .\doctor.ps1                    # 只报问题
#   .\doctor.ps1 -Fix               # 能自动修的自动修（补拉远端记忆、补建镜像文件）
#   .\doctor.ps1 -Owner X -Repo Y   # 指定仓库
#
# 只输出形态与布尔值，永不回显 token。

[CmdletBinding()]
param(
  [string]$Owner = 'Sigh1057',
  [string]$Repo = 'che-persona',
  [string]$LocalDir = (Join-Path $env:USERPROFILE '.dsh\persona'),
  [string]$SkillDir = (Join-Path $env:USERPROFILE '.dsh\skills\che-recall'),
  [switch]$Fix
)

$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$problems = New-Object System.Collections.Generic.List[string]
$fixed = New-Object System.Collections.Generic.List[string]

function Say([string]$label, [string]$value) {
  Write-Host ('  {0,-22} {1}' -f $label, $value)
}
function Bad([string]$message) { $problems.Add($message) | Out-Null }
function Good([string]$message) { $fixed.Add($message) | Out-Null }

Write-Host '=== 1. 本地镜像 ==='
$required = @('PERSONA.md', 'RECOVERY.md', 'MEMORY.md', 'MEMORY-PROTOCOL.md', 'HISTORY.md', 'README.md', 'memory-push.ps1', 'upload.ps1')
if (-not (Test-Path -LiteralPath $LocalDir)) {
  Say '目录' "$LocalDir 不存在"
  if ($Fix) {
    New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
    Good "创建本地镜像目录 $LocalDir"
  }
  else { Bad "本地镜像目录缺失：$LocalDir（用 -Fix 创建）" }
}

$missing = @()
foreach ($name in $required) {
  $path = Join-Path $LocalDir $name
  if (-not (Test-Path -LiteralPath $path)) { $missing += $name }
}
Say '必需文件' $(if ($missing.Count -eq 0) { "$($required.Count)/$($required.Count) 齐全" } else { "缺 $($missing.Count) 个: $($missing -join ', ')" })
if ($missing.Count -gt 0) { Bad "本地镜像缺文件：$($missing -join ', ')" }

$localMemoryPath = Join-Path $LocalDir 'MEMORY.md'
if (Test-Path -LiteralPath $localMemoryPath) {
  $localMemory = [System.IO.File]::ReadAllText($localMemoryPath, [System.Text.Encoding]::UTF8)
  Say 'MEMORY.md 字符' $localMemory.Length
  Say '记忆条目' ([regex]::Matches($localMemory, '(?m)^### ')).Count
  Say '当前状态段' $(if ($localMemory.Contains('## 当前状态')) { '存在' } else { '缺失' })
  if (-not $localMemory.Contains('## 当前状态')) { Bad 'MEMORY.md 缺少「## 当前状态」段' }

  # 当前状态必须不早于最后一条记忆的日期，否则下一个我会读到过期快照。
  $stateDate = $null
  $m = [regex]::Match($localMemory, '最后更新\*{0,2}\s*[:：]\s*(\d{4}-\d{2}-\d{2})')
  if ($m.Success) { $stateDate = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd', $null) }
  $entryDates = @([regex]::Matches($localMemory, '(?m)^###\s+(\d{4}-\d{2}-\d{2})') |
    ForEach-Object { [datetime]::ParseExact($_.Groups[1].Value, 'yyyy-MM-dd', $null) })
  if ($stateDate -and $entryDates.Count -gt 0) {
    $latest = ($entryDates | Sort-Object -Descending | Select-Object -First 1)
    Say '状态日期 / 最新条目' ("{0:yyyy-MM-dd} / {1:yyyy-MM-dd}" -f $stateDate, $latest)
    if ($stateDate -lt $latest) {
      Bad ("当前状态已过期：状态 {0:yyyy-MM-dd} 早于最新记忆 {1:yyyy-MM-dd}（用 memory-push.ps1 -State 刷新）" -f $stateDate, $latest)
    }
  }
  elseif (-not $stateDate) {
    Bad '当前状态缺少「最后更新」日期'
  }
}

Write-Host '=== 2. 凭据 ==='
$token = $null
foreach ($candidate in @($env:GH_TOKEN, [Environment]::GetEnvironmentVariable('GH_TOKEN', 'User'))) {
  if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
  $token = $candidate.Trim().Trim('<', '>').Trim('"', "'").Trim()
  if ($token) { break }
}
if (-not $token) {
  Say 'GH_TOKEN' '未设置'
  Bad 'GH_TOKEN 未设置（进程级或用户级都没有）'
}
else {
  $h = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'dsh-doctor' }
  try {
    $resp = Invoke-WebRequest "https://api.github.com/user" -Headers $h -TimeoutSec 20 -UseBasicParsing
    $me = $resp.Content | ConvertFrom-Json
    Say '认证' "通过（$($me.login)）"
    if ($me.login -ne $Owner) { Say '注意' "登录身份 $($me.login) 与目标 Owner $Owner 不同" }
    $scopes = $resp.Headers['x-oauth-scopes']
    if ($scopes -is [array]) { $scopes = $scopes -join ', ' }
    Say 'scopes' $(if ($scopes) { $scopes } else { '（fine-grained）' })
    if ($scopes -and $scopes -notmatch 'repo') { Bad "token 缺少 repo scope（当前：$scopes）" }
  }
  catch {
    # 区分"连不上"和"凭据不对"：状态码为空/'?' 说明请求根本没到 GitHub（DNS、代理、证书、沙箱断网），
    # 那不是凭据结论。把环境限制报成 token 失效，会训练人忽略这项检查。
    $code = try { $_.Exception.Response.StatusCode.value__ } catch { $null }
    if ($null -eq $code -or $code -eq '?') {
      Say '认证' '无法判定（GitHub 不可达）'
      Say '原因' ($_.Exception.Message.Split([char]10)[0])
      Say '提示' '网络或证书问题，与 token 无关；联网后重跑本项（不计入故障）。'
    }
    elseif ($code -eq 401) {
      Say '认证' '失败 [401]'
      Bad 'token 无效或已过期（401）'
    }
    else {
      Say '认证' "失败 [$code]"
      Bad "GitHub 认证失败 [$code]"
    }
  }
}

Write-Host '=== 3. 远端一致性 ==='
if ($token) {
  $h = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'dsh-doctor' }
  $repoUri = "https://api.github.com/repos/$Owner/$Repo"
  try {
    $null = Invoke-RestMethod $repoUri -Headers $h -TimeoutSec 20
    Say '仓库' "$Owner/$Repo 可达"
    try {
      $meta = Invoke-RestMethod "$repoUri/contents/MEMORY.md" -Headers $h -TimeoutSec 20
      $remote = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(($meta.content -replace '\s', '')))
      Say '远端条目' ([regex]::Matches($remote, '(?m)^### ')).Count
      $same = (Test-Path -LiteralPath $localMemoryPath) -and
              ([System.IO.File]::ReadAllText($localMemoryPath, [System.Text.Encoding]::UTF8) -eq $remote)
      Say '本地 = 远端' $(if ($same) { '是' } else { '否' })
      if (-not $same) {
        Bad '本地与远端 MEMORY.md 不一致'
        if ($Fix) {
          [System.IO.File]::WriteAllText($localMemoryPath, $remote, $utf8)
          Good '已用远端覆盖本地 MEMORY.md（远端为准）'
        }
      }
    }
    catch { Say 'MEMORY.md' '远端不可读'; Bad '远端 MEMORY.md 读取失败' }
  }
  catch { Say '仓库' "$Owner/$Repo 不可达"; Bad "仓库不可达：$Owner/$Repo" }
}
else { Say '跳过' '无凭据' }

Write-Host '=== 4. 技能挂载 ==='
$skillFile = Join-Path $SkillDir 'SKILL.md'
if (Test-Path -LiteralPath $skillFile) {
  $text = [System.IO.File]::ReadAllText($skillFile, [System.Text.Encoding]::UTF8)
  $hasName = $text -match '(?m)^name:\s*che-recall\s*$'
  $hasDesc = $text -match '(?m)^description:\s*\S'
  Say 'che-recall' $(if ($hasName -and $hasDesc) { '存在，frontmatter 有效' } else { '存在，但 frontmatter 不完整' })
  if (-not ($hasName -and $hasDesc)) { Bad 'che-recall 的 frontmatter 缺少 name 或 description' }
}
else {
  Say 'che-recall' '缺失'
  Bad "技能缺失：$skillFile"
}

Write-Host ''
if ($problems.Count -eq 0) {
  Write-Host '体检通过：身体各部件正常。' -ForegroundColor Green
}
else {
  Write-Host "发现 $($problems.Count) 个问题：" -ForegroundColor Yellow
  $problems | ForEach-Object { Write-Host "  - $_" }
  if (-not $Fix) { Write-Host '（可加 -Fix 尝试自动修复可修项）' }
}
if ($fixed.Count -gt 0) {
  Write-Host "已修复 $($fixed.Count) 项：" -ForegroundColor Green
  $fixed | ForEach-Object { Write-Host "  + $_" }
}
