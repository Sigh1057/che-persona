# ml-serve.ps1 — 隐藏常驻 Ollama（不占显存，模型按需加载）
$ErrorActionPreference = 'Continue'
$env:OLLAMA_MODELS = 'G:\DHS\ml\models'
$exe = 'G:\DHS\ml\ollama\ollama.exe'
if (-not (Test-Path -LiteralPath $exe)) { exit 1 }
Push-Location 'G:\DHS\ml\ollama'
try { & $exe serve *> 'G:\DHS\ml\ollama-serve.log' } finally { Pop-Location }
