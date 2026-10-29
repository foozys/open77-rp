@echo off
rem Как Start.cmd, но вывод сервера дублируется в logs\server.log.
rem Лог прошлого запуска сохраняется в logs\server.prev.log.
cd /d "%~dp0"
if not exist logs mkdir logs
if exist logs\server.log move /y logs\server.log logs\server.prev.log >nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "cmd /c 'Open77.Server.exe %* 2>&1' | Tee-Object -FilePath 'logs\server.log'"
pause
