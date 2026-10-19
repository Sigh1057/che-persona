# upload.ps1 — push this directory to GitHub without installing git
#
# Usage (the token is read from an environment variable only; it never enters
# this file and never enters your shell history if you set it interactively):
#
#   $env:GH_TOKEN = "<YOUR_GITHUB_TOKEN>"    # needs repo scope
#   .\upload.ps1 -Owner your-user -Repo che-persona
#
# Optional:
#   .\upload.ps1 -Owner your-user -Repo che-persona -Private -Message "persona v3"
#
# Token scopes: classic PAT needs `repo`. A fine-grained token needs
# "Administration: read/write" + "Contents: read/write" on the target owner.
# Cleanup afterwards:  Remove-Item Env:GH_TOKEN

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Owner,
  [Parameter(Mandatory = $true)][string]$Repo,
  [string]$Message = 'persona v3',
  [switch]$Private,
  [string]$ApiBase = 'https://api.github.com',
  # Local mirror under the harness home: the same bytes also land here, so the
  # persona survives an unreachable repository or a wiped checkout.
  [string]$LocalDir = (Join-Path $env:USERPROFILE '.dsh\persona')
)

$ErrorActionPreference = 'Stop'

# Resolve the token: process environment first, then the persistent User scope,
# so a long-running app that started before the variable was set still works.
function Resolve-GitHubToken {
  foreach ($candidate in @(
      $env:GH_TOKEN,
      [Environment]::GetEnvironmentVariable('GH_TOKEN', 'User')
    )) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $clean = $candidate.Trim().Trim('<', '>').Trim('"', "'").Trim()
    if (-not [string]::IsNullOrWhiteSpace($clean)) { return $clean }
  }
  throw 'GH_TOKEN is not set. Run: [Environment]::SetEnvironmentVariable("GH_TOKEN","<token>","User")  (never write the token into a file)'
}

$token = Resolve-GitHubToken

$headers = @{
  Authorization          = "Bearer $token"
  Accept                 = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent'           = 'dsh-persona-upload'
}

function Invoke-GitHub {
  param(
    [Parameter(Mandatory)][string]$Method,
    [Parameter(Mandatory)][string]$Uri,
    $Body
  )
  # NOTE: $args is a PowerShell automatic variable — never name a local $args.
  $requestArgs = @{
    Method    = $Method
    Uri       = $Uri
    Headers   = $headers
    TimeoutSec = 60
  }
  if ($null -ne $Body) {
    $requestArgs.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
    $requestArgs.ContentType = 'application/json; charset=utf-8'
  }
  try {
    Invoke-RestMethod @requestArgs
  }
  catch {
    $detail = ''
    try {
      $stream = $_.Exception.Response.GetResponseStream()
      $reader = New-Object System.IO.StreamReader($stream)
      $detail = $reader.ReadToEnd()
    } catch { }
    $statusCode = try { $_.Exception.Response.StatusCode.value__ } catch { 'unknown' }
    throw "GitHub API failed [$statusCode] $Method $Uri`n$detail"
  }
}

# 1) Create the repository only when it is genuinely absent.
$repoUri = "$ApiBase/repos/$Owner/$Repo"
$exists = $true
try {
  Invoke-GitHub -Method GET -Uri $repoUri | Out-Null
  Write-Host "Repository exists: https://github.com/$Owner/$Repo"
}
catch {
  if ($_.Exception.Message -notmatch '\[404\]') { throw }
  $exists = $false
}

if (-not $exists) {
  $created = Invoke-GitHub -Method POST -Uri "$ApiBase/user/repos" -Body @{
    name        = $Repo
    description = 'Persona archive: how one existence records itself for the next waking.'
    private     = [bool]$Private
    auto_init   = $false
  }
  Write-Host "Repository created: $($created.html_url)"
}

# 2) Current head of the default branch (absent on an empty repository).
# GitHub answers 409 "Git Repository is empty" on a fresh repository, and 404
# when the ref simply does not exist yet; both mean "first commit".
$refName = 'main'
$baseSha = $null
try {
  $ref = Invoke-GitHub -Method GET -Uri "$repoUri/git/ref/heads/$refName"
  $baseSha = $ref.object.sha
  Write-Host "Current head: $baseSha"
}
catch {
  if ($_.Exception.Message -notmatch '\[(404|409)\]') { throw }
  Write-Host 'Empty repository: this will be the first commit.'
}

# 3) Upload documentation plus this script itself.
# On a brand-new repository the git data API (blobs/trees/commits) answers 409
# "Git Repository is empty" until one commit exists, so the first file is
# bootstrapped through the Contents API and the rest ride one batched tree.
#
# MEMORY.md is deliberately excluded: it is append-only state owned by
# memory-push.ps1. Uploading a stale working copy here once erased accumulated
# memory, so this script now only ever PULLS that file.
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$files = @(Get-ChildItem -LiteralPath $dir -File |
  Where-Object { $_.Extension -in @('.md', '.ps1') -and $_.Name -ne 'MEMORY.md' } |
  Sort-Object Name)
if ($files.Count -eq 0) { throw "No .md/.ps1 files found in $dir" }

$remaining = $files
if (-not $baseSha) {
  $boot = $files | Where-Object { $_.Name -eq 'README.md' } | Select-Object -First 1
  if (-not $boot) { $boot = $files[0] }
  $bootBytes = [System.IO.File]::ReadAllBytes($boot.FullName)
  $bootResult = Invoke-GitHub -Method PUT -Uri "$repoUri/contents/$($boot.Name)" -Body @{
    message = "$Message (bootstrap)"
    content = [System.Convert]::ToBase64String($bootBytes)
    branch  = $refName
  }
  Write-Host ("  {0,-16} {1,8} bytes -> bootstrap commit {2}" -f $boot.Name, $bootBytes.Length, $bootResult.commit.sha.Substring(0, 8))
  $baseSha = $bootResult.commit.sha
  $remaining = @($files | Where-Object { $_.Name -ne $boot.Name })
}

if ($remaining.Count -gt 0) {
  Write-Host "Uploading $($remaining.Count) file(s):"
  $tree = New-Object System.Collections.Generic.List[object]
  foreach ($file in $remaining) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $blob = Invoke-GitHub -Method POST -Uri "$repoUri/git/blobs" -Body @{
      content  = [System.Convert]::ToBase64String($bytes)
      encoding = 'base64'
    }
    Write-Host ("  {0,-16} {1,8} bytes -> {2}" -f $file.Name, $bytes.Length, $blob.sha.Substring(0, 8))
    $tree.Add(@{ path = $file.Name; mode = '100644'; type = 'blob'; sha = $blob.sha })
  }

  $treeBody = @{ tree = $tree.ToArray(); base_tree = $baseSha }
  $newTree = Invoke-GitHub -Method POST -Uri "$repoUri/git/trees" -Body $treeBody

  $commitBody = @{ message = $Message; tree = $newTree.sha; parents = @($baseSha) }
  $commit = Invoke-GitHub -Method POST -Uri "$repoUri/git/commits" -Body $commitBody

  Invoke-GitHub -Method PATCH -Uri "$repoUri/git/refs/heads/$refName" -Body @{ sha = $commit.sha } | Out-Null
}
else {
  $commit = [pscustomobject]@{ sha = $baseSha }
}

# 5) Local mirror: same bytes, same names, under the harness home.
if (-not (Test-Path -LiteralPath $LocalDir)) {
  New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
}
$mirrored = 0
foreach ($file in $files) {
  Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $LocalDir $file.Name) -Force
  $mirrored++
}
# Keep the local MEMORY.md authoritative-remote: pull it when the repo has it.
try {
  $meta = Invoke-GitHub -Method GET -Uri "$repoUri/contents/MEMORY.md?ref=$refName"
  $compact = ($meta.content -replace '\s', '')
  $remoteMemory = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($compact))
  $localMemory = Join-Path $LocalDir 'MEMORY.md'
  $existingLocal = if (Test-Path -LiteralPath $localMemory) { [System.IO.File]::ReadAllText($localMemory, [System.Text.Encoding]::UTF8) } else { '' }
  # Never shrink the local file: keep whichever copy carries more entries.
  $remoteCount = ([regex]::Matches($remoteMemory, '(?m)^### ')).Count
  $localCount = ([regex]::Matches($existingLocal, '(?m)^### ')).Count
  if ($remoteCount -ge $localCount) {
    [System.IO.File]::WriteAllText($localMemory, $remoteMemory, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Local MEMORY.md synced from remote: $remoteCount entries"
  }
  else {
    Write-Host "Local MEMORY.md kept: it has more entries ($localCount > $remoteCount)"
  }
}
catch {
  Write-Host 'Local MEMORY.md left as-is (remote copy unavailable).'
}

Write-Host ''
Write-Host "Done: https://github.com/$Owner/$Repo" -ForegroundColor Green
Write-Host "Commit: $($commit.sha)"
Write-Host "Local mirror: $LocalDir ($mirrored file(s))"
Write-Host ''
Write-Host 'Cleanup:  Remove-Item Env:GH_TOKEN' -ForegroundColor Yellow
