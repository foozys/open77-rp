# Бэкап базы OPEN//77 RP (Windows). Пара для Linux — backup.sh.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\ops\backup.ps1
#   — дамп в backups\open77-ГГГГММДД-ЧЧММСС.sql.gz
#
# Строка подключения — только из OP77_DATABASE_CONNECTION (процесса, иначе пользователя,
# иначе машины); пароль уходит в mariadb-dump через временный файл, не через командную
# строку. OP77_BACKUP_DIR — папка (по умолчанию <корень сервера>\backups),
# OP77_BACKUP_KEEP — сколько последних дампов хранить (по умолчанию 14).
# Код выхода: 0 — дамп готов и проверен, иначе ошибка (старые дампы не трогаются).

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
$script:OpsName = 'backup'

$dir = Get-OpsSetting 'OP77_BACKUP_DIR'; if (-not $dir) { $dir = Join-Path $script:OpsRoot 'backups' }
$keepText = Get-OpsSetting 'OP77_BACKUP_KEEP'; if (-not $keepText) { $keepText = '14' }
$keep = 0
if (-not [int]::TryParse($keepText, [ref]$keep) -or $keep -lt 1) { Stop-Ops 'OP77_BACKUP_KEEP должно быть числом >= 1' }

$db = Initialize-Db
New-Item -ItemType Directory -Force $dir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $dir "open77-$stamp.sql.gz"
$sql = Join-Path $dir "open77-$stamp.sql.part"
try {
    # --single-transaction: согласованный снимок InnoDB без блокировки игры. Ошибки — в файл
    # (--log-error): stderr внешней программы в Windows PowerShell 5.1 обрывает скрипт.
    & $db.Dump "--defaults-extra-file=$($db.Cnf)" --single-transaction --routines --triggers --events `
        --default-character-set=utf8mb4 "--result-file=$sql" "--log-error=$sql.err" $db.Name
    $code = $LASTEXITCODE
    if (Test-Path "$sql.err") {
        Get-Content "$sql.err" | Where-Object { $_ -and $_ -notmatch 'ssl-verify-server-cert' } |
            ForEach-Object { [Console]::Error.WriteLine("backup: $_") }
    }
    if ($code -ne 0) { Stop-Ops "mariadb-dump завершился с кодом $code" }
    if ((Get-Content $sql -Tail 1 -Encoding UTF8) -notmatch 'Dump completed') { Stop-Ops "дамп оборван: $sql" }
    $tables = (Select-String -Path $sql -Pattern '^CREATE TABLE' | Measure-Object).Count

    $src = [IO.File]::OpenRead($sql)
    try {
        $dst = [IO.File]::Create("$out.part")
        try {
            $gz = New-Object IO.Compression.GZipStream($dst, [IO.Compression.CompressionLevel]::Optimal)
            try { $src.CopyTo($gz) } finally { $gz.Dispose() }
        } finally { $dst.Dispose() }
    } finally { $src.Dispose() }
    Move-Item -Force "$out.part" $out
} finally {
    Remove-DbCnf $db
    Remove-Item -Force -ErrorAction SilentlyContinue $sql, "$sql.err", "$out.part"
}

# Ротация: оставить последние $keep.
Get-ChildItem $dir -Filter 'open77-*.sql.gz' | Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $keep | Remove-Item -Force

$size = '{0:N1} MB' -f ((Get-Item $out).Length / 1MB)
Write-Output "backup: $out ($size, таблиц $tables, хранится последних $keep)"
exit 0
