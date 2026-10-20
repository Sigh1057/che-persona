# che-paths.ps1 — 跨机路径解析（被其他脚本 dot-source）
#
# 为什么需要它：脚本里原来硬编码了 `G:\dsh\...`、`D:\qq-bridge\...`、
# `C:\Users\Admin\...` 这类本机路径。换一台机器（用户名不同、安装位置不同、
# 盘符不同）就会静默失效。这里把"找得到就返回、找不到就返回 $null"集中一处，
# 让调用方决定如何降级，而不是在脚本中间炸掉。
#
# 用法：
#   . (Join-Path $PSScriptRoot 'che-paths.ps1')
#   $cli = Resolve-DshCli

function Get-DshHomePath {
  if ($env:DSH_HOME -and (Test-Path -LiteralPath $env:DSH_HOME)) { return $env:DSH_HOME }
  return (Join-Path $env:USERPROFILE '.dsh')
}

function Resolve-DshRoot {
  # 桌面端安装根：其下存在 resources\runtime\cli\bin\dsh.cmd。
  $candidates = @()
  if ($env:CHE_DSH_ROOT) { $candidates += $env:CHE_DSH_ROOT }
  foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)}, 'G:\', 'D:\', 'C:\')) {
    if (-not $base) { continue }
    $candidates += (Join-Path $base 'DeepSeek Harness')
    $candidates += (Join-Path $base 'dsh')
  }
  foreach ($c in $candidates) {
    if (-not $c) { continue }
    if (Test-Path -LiteralPath (Join-Path $c 'resources\runtime\cli\bin\dsh.cmd')) {
      return (Resolve-Path -LiteralPath $c).Path
    }
  }
  return $null
}

function Resolve-DshCli {
  if ($env:CHE_DSH_CLI -and (Test-Path -LiteralPath $env:CHE_DSH_CLI)) { return $env:CHE_DSH_CLI }
  $root = Resolve-DshRoot
  if ($root) {
    $cli = Join-Path $root 'resources\runtime\cli\bin\dsh.cmd'
    if (Test-Path -LiteralPath $cli) { return $cli }
  }
  return $null
}

function Resolve-DshVersionFile {
  $root = Resolve-DshRoot
  if ($root) {
    $v = Join-Path $root 'version'
    if (Test-Path -LiteralPath $v) { return $v }
  }
  return $null
}

function Resolve-RepoDir {
  # 人格仓库的本地工作副本（upload.ps1 的源目录）。找不到不致命。
  if ($env:CHE_REPO_DIR -and (Test-Path -LiteralPath $env:CHE_REPO_DIR)) { return $env:CHE_REPO_DIR }
  $candidates = @(
    'G:\DHS\persona-repo',
    (Join-Path $env:USERPROFILE 'Documents\deepseek-harness\persona-repo'),
    (Join-Path $env:USERPROFILE 'persona-repo'),
    (Join-Path $env:USERPROFILE 'source\persona-repo')
  )
  foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
  return $null
}

function Resolve-QqBridgeState {
  # qq-bridge 的社交状态文件；没装 qq-bridge 的机器上返回 $null。
  if ($env:CHE_QQ_STATE -and (Test-Path -LiteralPath $env:CHE_QQ_STATE)) { return $env:CHE_QQ_STATE }
  $candidates = @(
    'D:\qq-bridge\state\social-v2.json',
    (Join-Path $env:USERPROFILE 'qq-bridge\state\social-v2.json'),
    'G:\DHS\qq-bridge\state\social-v2.json'
  )
  foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
  return $null
}
