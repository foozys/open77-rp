@echo off
rem Как Start.cmd, но вывод сервера пишется в logs\server.log (лог прошлого запуска —
rem logs\server.prev.log, более ранние — logs\server-<дата>.log, последние OP77_LOG_KEEP).
rem Перед запуском — tools\ops\prestart.ps1: ротация логов и бэкап базы в backups\
rem (OP77_BACKUP_ON_START=0 — без бэкапа; OP77_BACKUP_REQUIRED=1 — без бэкапа не запускать).
rem
rem Сервер пишет прямо в файл: так он никогда не ждёт консоль. Через конвейер PowerShell
rem (Tee-Object) сервер подвисал, когда вывода много (трафик, толпа), а хвост лога при
rem закрытии терялся. Команды сервера (refresh, quit, restart ...) вводятся в этом окне.
rem Живой лог без шума NPC показывает второе окно «Open77 log».
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ops\prestart.ps1
if errorlevel 1 (
  echo Start cancelled: tools\ops\prestart.ps1 failed.
  pause
  exit /b 1
)
start "Open77 log" powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -Path 'logs\server.log' -Encoding UTF8 -Wait | Where-Object { $_ -notmatch '\[npc-authority\]|NPC spawn projection|\[crowd\] (task|visit)|retired reason=' }"
echo Server log: window "Open77 log" and logs\server.log. Type server commands here.
Open77.Server.exe %* >> logs\server.log 2>&1
pause
