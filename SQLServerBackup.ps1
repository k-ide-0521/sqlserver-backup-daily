# =============================================
# SQLServer 曜日別フルバックアップ & 検証
# 複数のデータベースを曜日別ファイルに毎日バックアップし、
# バックアップ完了後に整合性を検証する
# =============================================

# ---- パラメータ設定ここから ----
$Databases  = @("SAMPLE_DB1", "SAMPLE_DB2", "SAMPLE_DB3", "SAMPLE_DB4")
$BackupRoot = "D:\DB_BKU"
$SqlServer  = "localhost"

$LogDir  = "D:\Logs\SQLBackup"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir "$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
# ---- パラメータ設定ここまで ----

# 曜日 → ファイル名マッピング
$DayMap = @{
    "Sunday"    = "Sun"
    "Monday"    = "Mon"
    "Tuesday"   = "Tue"
    "Wednesday" = "Wed"
    "Thursday"  = "Thr"
    "Friday"    = "Fri"
    "Saturday"  = "Sat"
}

$DayKey  = (Get-Date).DayOfWeek.ToString()
$DayFile = $DayMap[$DayKey]
$DayJP   = (Get-Date -Format "dddd" -Culture "ja-JP")

# ログ出力関数
function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

# 処理開始
Write-Log "===== 処理開始 対象DB数: $($Databases.Count) ====="

foreach ($db in $Databases) {

    $BakPath = "$BackupRoot\bk_$db\$DayFile.bak"
    $BakName = "完全バックアップ${DayJP}03:00"

    # バックアップ実行SQL
    $BackupSql = @"
    BACKUP DATABASE [$db]
    TO DISK = N'$BakPath'
    WITH NOFORMAT, INIT, NAME = N'$BakName',
        SKIP, NOREWIND, NOUNLOAD,
        STATS = 10, CHECKSUM, STOP_ON_ERROR
"@

    # 検証SQL
    $VerifySql = @"
    DECLARE @backupSetId AS INT
    SELECT @backupSetId = position
    FROM msdb..backupset
    WHERE database_name = N'$db'
    AND backup_set_id = (
        SELECT MAX(backup_set_id) FROM msdb..backupset WHERE database_name = N'$db'
    )
    IF @backupSetId IS NULL
        BEGIN RAISERROR(N'確認に失敗しました。データベース ''$db'' のバックアップ情報が見つかりません。', 16, 1) END
    RESTORE VERIFYONLY FROM DISK = N'$BakPath'
    WITH FILE = @backupSetId, NOUNLOAD, NOREWIND
"@

    try {
        Write-Log "[$db] バックアップ開始 Path=$BakPath"
        Invoke-Sqlcmd -ServerInstance $SqlServer -Query $BackupSql -QueryTimeout 600
        Write-Log "[$db] バックアップ完了 検証開始"
        Invoke-Sqlcmd -ServerInstance $SqlServer -Query $VerifySql -QueryTimeout 120
        Write-Log "[$db] 検証OK"
    }
    catch {
        Write-Log "[$db] [エラー] $($_.Exception.Message)"
    }
}

Write-Log "===== 処理終了 ====="