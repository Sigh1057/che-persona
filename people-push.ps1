# people-push.ps1 — 把人物账本备份到**私有**仓库
#
# 为什么单独一个脚本、单独一个仓库：
#   `people/*.json` 是对人的判断，比 MEMORY.md 更私密。公开仓库只放人格与记忆摘要，
#   这类内容一律进 `Sigh1057/che-people`（private）。
#
# 为什么用 Contents API 而不是 git：
#   文件少（每人一个 json + 一个 INDEX.md），逐个比对远程 sha 再 PUT 就够，
#   不必为备份在本地再维护一个 clone。
#
# 凭据：只从环境变量读（进程级优先，其次用户级），全程不回显。
#
# 用法：
#   .\people-push.ps1            # 同步到私有仓库
#   .\people-push.ps1 -DryRun    # 只报差异，不写
[CmdletBinding()]
param(
  [string]$Owner = 'Sigh1057',
  [string]$Repo  = 'che-people',
  [string]$Dir   = (Join-Path $env:USERPROFILE '.dsh\persona\people'),
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Get-Token {
  foreach ($c in @($env:GH_TOKEN, [Environment]::GetEnvironmentVariable('GH_TOKEN','User'))) {
    if ([string]::IsNullOrWhiteSpace($c)) { continue }
    return ($c.Trim().Trim('<','>').Trim('"',"'").Trim())
  }
  return $null
}

$token = Get-Token
if (-not $token) { Write-Output '没有可用凭据（GH_TOKEN 未设置），跳过备份。'; return }
if (-not (Test-Path -LiteralPath $Dir)) { Write-Output "账本目录不存在：$Dir"; return }

$h = @{
  Authorization = "Bearer $token"
  Accept        = 'application/vnd.github+json'
  'User-Agent'  = 'che-people-push'
  'X-GitHub-Api-Version' = '2022-11-28'
}
$api = "https://api.github.com/repos/$Owner/$Repo/contents"

# 待备份：所有 *.json（排除点开头的内部文件）+ INDEX.md
$files = @()
$files += Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File |
  Where-Object { -not $_.BaseName.StartsWith('.') }
$idx = Join-Path $Dir 'INDEX.md'
if (Test-Path -LiteralPath $idx) { $files += Get-Item -LiteralPath $idx }

if ($files.Count -eq 0) { Write-Output '没有可备份的文件。'; return }

$pushed = 0; $same = 0; $failed = 0
foreach ($f in $files) {
  $name = $f.Name
  $localText = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
  $localB64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($localText))

  $sha = $null
  try {
    $meta = Invoke-RestMethod "$api/$name" -Headers $h -TimeoutSec 25
    $sha = $meta.sha
    $remoteText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(($meta.content -replace '\s','')))
    if ($remoteText -eq $localText) { Write-Output ("  未变 {0}" -f $name); $same++; continue }
  } catch {
    $code = try { $_.Exception.Response.StatusCode.value__ } catch { '?' }
    if ($code -ne 404) { Write-Output ("  读取失败 {0}（HTTP {1}）" -f $name, $code); $failed++; continue }
  }

  if ($DryRun) { Write-Output ("  [演练] 将上传 {0}（{1} 字节）" -f $name, $f.Length); $pushed++; continue }

  $payload = @{
    message = ('sync: {0}' -f $name)
    content = $localB64
    branch  = 'main'
  }
  if ($sha) { $payload.sha = $sha }
  try {
    Invoke-RestMethod "$api/$name" -Method Put -Headers $h `
      -Body ($payload | ConvertTo-Json -Compress) -ContentType 'application/json' -TimeoutSec 30 | Out-Null
    Write-Output ("  已上传 {0}" -f $name)
    $pushed++
  } catch {
    Write-Output ("  上传失败 {0}：{1}" -f $name, $_.Exception.Message)
    $failed++
  }
}

Write-Output ("备份结束：上传 {0} / 未变 {1} / 失败 {2} → {3}" -f $pushed, $same, $failed, "$Owner/$Repo")
if ($failed -gt 0) { exit 1 }
