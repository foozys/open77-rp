# Общее для эксплуатационных скриптов (Windows): подключение к MariaDB из
# OP77_DATABASE_CONNECTION. Подключается через `. (Join-Path $PSScriptRoot 'lib.ps1')`.
#
# Initialize-Db возвращает объект: Host, Port, Name, User, Cnf (временный файл [client] с
# паролем — удалить через Remove-DbCnf), Dump, Client.

$script:OpsName = 'ops'
$script:OpsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Get-OpsSetting($name) {
    foreach ($scope in 'Process', 'User', 'Machine') {
        $value = [Environment]::GetEnvironmentVariable($name, $scope)
        if ($value) { return $value }
    }
    return $null
}

function Stop-Ops($text) { [Console]::Error.WriteLine("$($script:OpsName): $text"); exit 1 }

function Find-DbTool([string[]]$names) {
    foreach ($name in $names) {
        $cmd = Get-Command "$name.exe" -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    foreach ($name in $names) {
        $found = Get-ChildItem "C:\Program Files\MariaDB*\bin\$name.exe", "C:\Program Files\MySQL\*\bin\$name.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Initialize-Db {
    $conn = Get-OpsSetting 'OP77_DATABASE_CONNECTION'
    if (-not $conn) { Stop-Ops 'переменная OP77_DATABASE_CONNECTION не задана' }
    $fields = @{}
    foreach ($part in $conn -split ';') {
        if ($part -match '^\s*([^=]+?)\s*=(.*)$') { $fields[$matches[1].ToLower()] = $matches[2] }
    }
    $pick = { param([string[]]$names) foreach ($n in $names) { if ($fields.ContainsKey($n)) { return $fields[$n] } }; return $null }
    $db = [pscustomobject]@{
        Host = (& $pick 'server', 'host', 'data source', 'datasource', 'address')
        Port = (& $pick 'port')
        Name = (& $pick 'database', 'initial catalog')
        User = (& $pick 'user id', 'uid', 'user', 'username', 'user name')
        Cnf = $null
        Dump = (Find-DbTool 'mariadb-dump', 'mysqldump')
        Client = (Find-DbTool 'mariadb', 'mysql')
    }
    if (-not $db.Host) { $db.Host = '127.0.0.1' }
    if (-not $db.Port) { $db.Port = '3306' }
    if (-not $db.Name) { Stop-Ops 'в строке подключения нет Database' }
    if (-not $db.User) { Stop-Ops 'в строке подключения нет User ID' }
    if (-not $db.Dump -or -not $db.Client) { Stop-Ops 'не найдены mariadb / mariadb-dump (клиент MariaDB)' }
    $pass = & $pick 'password', 'pwd'; if ($null -eq $pass) { $pass = '' }
    $esc = { param($s) ($s -replace '\\', '\\' -replace '"', '\"') }
    $db.Cnf = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($db.Cnf, "[client]`nhost=`"$(& $esc $db.Host)`"`nport=$($db.Port)`nuser=`"$(& $esc $db.User)`"`npassword=`"$(& $esc $pass)`"`n",
        (New-Object Text.UTF8Encoding $false))
    return $db
}

function Remove-DbCnf($db) { if ($db -and $db.Cnf) { Remove-Item -Force -ErrorAction SilentlyContinue $db.Cnf } }

# Запрос без заголовков: строки результата. Ошибки — в файл, чтобы Windows PowerShell 5.1
# не обрывал скрипт на stderr внешней программы.
function Invoke-DbQuery($db, [string]$database, [string]$sql) {
    $ErrorActionPreference = 'Continue'
    $err = [IO.Path]::GetTempFileName()
    try {
        $out = & $db.Client "--defaults-extra-file=$($db.Cnf)" -N -B --default-character-set=utf8mb4 -D $database -e $sql 2>$err
        if ($LASTEXITCODE -ne 0) { throw ((Get-Content $err -Raw) -replace '\s+$', '') }
        return $out
    } finally { Remove-Item -Force -ErrorAction SilentlyContinue $err }
}
