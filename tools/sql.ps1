# Ejecuta un archivo .sql en el proyecto Supabase "Merch Festivalazo" via Management API.
# Uso: powershell -File tools\sql.ps1 supabase\001_esquema.sql
param([Parameter(Mandatory)][string]$archivo)
$ref = 'qfnaodezkfxplhnfngos'
$raiz = Split-Path $PSScriptRoot -Parent
$token = [System.IO.File]::ReadAllText((Join-Path $raiz "supabase-token.txt")).Trim()
$sql = [System.IO.File]::ReadAllText((Resolve-Path $archivo), [System.Text.Encoding]::UTF8)
$body = @{ query = $sql } | ConvertTo-Json -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
try {
  $r = Invoke-RestMethod -Method Post -Uri "https://api.supabase.com/v1/projects/$ref/database/query" `
    -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json; charset=utf-8' -Body $bytes
  $r | ConvertTo-Json -Depth 6
} catch {
  $_.ErrorDetails.Message
  exit 1
}
