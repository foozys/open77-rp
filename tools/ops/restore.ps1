# Восстановление базы из дампа backup.ps1 / backup.sh (Windows). Пара для Linux — restore.sh.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\ops\restore.ps1 <дамп.sql.gz> [база]
#       Проверка: дамп разворачивается в отдельную базу (по умолчанию test_<рабочая>_restore —
#       на её имя у пользователя обычно есть права), таблицы и строки сверяются с рабочей
#       базой, проверочная база удаляется (-Keep — оставить).
#   ... restore.ps1 -Replace <дамп.sql.gz>
#       Настоящее восстановление РАБОЧЕЙ базы. Только при ОСТАНОВЛЕННОМ сервере. Сначала
#       делается страховочный бэкап текущего состояния (backup.ps1), затем база пересоздаётся.
#
# Подключение — из OP77_DATABASE_CONNECTION, как у backup.ps1.

param(
    [Parameter(Mandatory = $true, Position = 0)][string]$File,
    [Parameter(Position = 1)][string]$Database,
    [switch]$Replace,
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
$script:OpsName = 'restore'

if (-not (Test-Path $File)) { Stop-Ops "нет файла $File" }
$File = (Resolve-Path $File).Path
$db = Initialize-Db
$plain = Join-Path ([IO.Path]::GetTempPath()) ("op77-restore-" + [Guid]::NewGuid().ToString('N') + '.sql')
try {
    if ($Replace) { $target = $db.Name } elseif ($Database) { $target = $Database } else { $target = "test_$($db.Name)_restore" }
    if ($target -notmatch '^[A-Za-z0-9_]+$') { Stop-Ops "недопустимое имя базы: $target" }
    if ($target -eq $db.Name -and -not $Replace) { Stop-Ops "$target — рабочая база: для восстановления в неё нужен -Replace (сервер остановлен)" }

    # Распаковать во временный файл: конвейер PowerShell 5.1 перекодирует текст во внешнюю программу.
    if ($File -like '*.gz') {
        $src = [IO.File]::OpenRead($File)
        try {
            $gz = New-Object IO.Compression.GZipStream($src, [IO.Compression.CompressionMode]::Decompress)
            try {
                $dst = [IO.File]::Create($plain)
                try { $gz.CopyTo($dst) } finally { $dst.Dispose() }
            } finally { $gz.Dispose() }
        } finally { $src.Dispose() }
    } else {
        Copy-Item $File $plain
    }
    if ((Get-Content $plain -Tail 1 -Encoding UTF8) -notmatch 'Dump completed') { Stop-Ops "дамп неполный (нет строки «Dump completed»): $File" }
    $dumpTables = (Select-String -Path $plain -Pattern '^CREATE TABLE' | Measure-Object).Count

    if ($Replace) {
        Write-Output "restore: страховочный бэкап текущей базы $($db.Name)..."
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'backup.ps1')
        if ($LASTEXITCODE -ne 0) { Stop-Ops 'страховочный бэкап не удался — восстановление отменено' }
        Invoke-DbQuery $db 'information_schema' "DROP DATABASE ``$target``; CREATE DATABASE ``$target`` CHARACTER SET utf8mb4" | Out-Null
    } else {
        $existing = Invoke-DbQuery $db 'information_schema' "SELECT COUNT(*) FROM TABLES WHERE TABLE_SCHEMA = '$target'"
        if ("$existing".Trim() -ne '0') { Stop-Ops "в базе $target уже есть таблицы ($existing) — удалите её или укажите другую" }
        try { Invoke-DbQuery $db 'information_schema' "CREATE DATABASE IF NOT EXISTS ``$target`` CHARACTER SET utf8mb4" | Out-Null }
        catch { Stop-Ops "нет прав создать базу $target — укажите базу, на которую у пользователя есть права ($_)" }
    }

    Write-Output "restore: загрузка $File -> $target..."
    Invoke-DbQuery $db $target ("source " + ($plain -replace '\\', '/')) | Out-Null

    # Сверка: таблиц столько же, сколько в дампе; строки — с рабочей базой (при проверке).
    $tables = @(Invoke-DbQuery $db 'information_schema' "SELECT TABLE_NAME FROM TABLES WHERE TABLE_SCHEMA = '$target' AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME")
    $diff = 0
    foreach ($table in $tables) {
        if (-not $table) { continue }
        $countSql = 'SELECT COUNT(*) FROM `' + $table + '`'
        $restored = ([string](Invoke-DbQuery $db $target $countSql)).Trim()
        if ($target -ne $db.Name) {
            try { $live = ([string](Invoke-DbQuery $db $db.Name $countSql)).Trim() } catch { $live = '-' }
            $mark = ''
            if ($restored -ne $live) { $mark = '  != (рабочая база могла измениться после дампа)'; $diff++ }
            Write-Output ('  {0,-44} {1,8}  рабочая {2,8}{3}' -f $table, $restored, $live, $mark)
        } else {
            Write-Output ('  {0,-44} {1,8}' -f $table, $restored)
        }
    }
    if ($target -ne $db.Name -and -not $Keep) {
        Invoke-DbQuery $db 'information_schema' "DROP DATABASE ``$target``" | Out-Null
        Write-Output "restore: проверочная база $target удалена"
    }
    if ($tables.Count -ne $dumpTables) { Stop-Ops "таблиц восстановлено $($tables.Count), в дампе $dumpTables" }
    Write-Output "restore: OK — таблиц $($tables.Count) из $dumpTables, расхождений строк с рабочей базой: $diff"
} finally {
    Remove-DbCnf $db
    Remove-Item -Force -ErrorAction SilentlyContinue $plain
}
exit 0
