@echo off
rem Как Start.cmd, но вывод сервера пишется в logs\server.log (лог прошлого запуска —
rem logs\server.prev.log).
rem
rem Сервер пишет прямо в файл: так он никогда не ждёт консоль. Через конвейер PowerShell
rem (Tee-Object) сервер подвисал, когда вывода много (трафик, толпа), а хвост лога при
rem закрытии терялся. Команды сервера (refresh, quit, restart ...) вводятся в этом окне.
rem Живой лог без шума NPC показывает второе окно «Open77 log».
cd /d "%~dp0"
if not exist logs mkdir logs
if exist logs\server.log move /y logs\server.log logs\server.prev.log >nul
type nul > logs\server.log
start "Open77 log" powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -Path 'logs\server.log' -Encoding UTF8 -Wait | Where-Object { $_ -notmatch '\[npc-authority\]|NPC spawn projection|\[crowd\] (task|visit)|retired reason=' }"
echo Server log: window "Open77 log" and logs\server.log. Type server commands here.
Open77.Server.exe %* >> logs\server.log 2>&1
pause
