# pet-start.ps1 — 启动 Live2D 桌宠（补齐 PATH 后交给 start_mio.ps1）
$ErrorActionPreference = 'Continue'
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
$root = 'G:\DHS\ml\live2d-mao\dsh-live2d-mao-main'
if (-not (Test-Path -LiteralPath $root)) { exit 1 }
Push-Location $root
try {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File (Join-Path $root 'start_mio.ps1') *> 'G:\DHS\ml\pet-start.log'
}
finally { Pop-Location }
