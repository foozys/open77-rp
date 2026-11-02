# Подготовка к запуску сервера (Windows): ротация логов и бэкап базы. Пара — prestart.sh.
# Вызывается из Start-Logged.cmd; можно и отдельно.
#
# Логи: logs\server.log — текущий запуск, logs\server.prev.log — прошлый, более ранние —
# logs\server-ГГГГММДД-ЧЧММСС.log, хранятся последние OP77_LOG_KEEP (по умолчанию 10).
# Бэкап: backup.ps1, если OP77_BACKUP_ON_START не 0. Не удался — предупреждение и запуск
# дальше; OP77_BACKUP_REQUIRED=1 — без бэкапа не запускать (код выхода 1).

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
$script:OpsName = 'prestart'
Set-Location $script:OpsRoot

$keep = 10
[void][int]::TryParse((Get-OpsSetting 'OP77_LOG_KEEP'), [ref]$keep)
if ($keep -lt 1) { $keep = 10 }

New-Item -ItemType Directory -Force logs | Out-Null
$prev = Get-Item logs\server.prev.log -ErrorAction SilentlyContinue
if ($prev -and $prev.Length -gt 0) {
    Move-Item -Force $prev.FullName ("logs\server-{0:yyyyMMdd-HHmmss}.log" -f $prev.LastWriteTime)
}
$cur = Get-Item logs\server.log -ErrorAction SilentlyContinue
if ($cur -and $cur.Length -gt 0) { Move-Item -Force $cur.FullName logs\server.prev.log }
Get-ChildItem logs -Filter 'server-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -Skip $keep | Remove-Item -Force
[IO.File]::WriteAllText((Join-Path $script:OpsRoot 'logs\server.log'), '')

if ((Get-OpsSetting 'OP77_BACKUP_ON_START') -ne '0') {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'backup.ps1')
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine('prestart: ВНИМАНИЕ — бэкап базы перед запуском не сделан')
        if ((Get-OpsSetting 'OP77_BACKUP_REQUIRED') -eq '1') { exit 1 }
    }
}
exit 0
