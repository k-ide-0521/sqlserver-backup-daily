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

$SmtpServer = "smtp.example.jp"
$SmtpPort   = 587
$MailFrom   = "system-server@example.co.jp"
$MailTo     = "system-group@example.co.jp"
$SmtpUser   = "user@example.co.jp"
$SmtpPass   = $env:SMTP_PASS
# ---- パラメータ設定ここまで ----

# ログ出力関数
function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

# メール送信関数
function Send-Mail {
    param([string]$Subject, [string]$mailBody)
    try {
        $MailParams = @{
            SmtpServer = $SmtpServer
            Port       = $SmtpPort
            From       = $MailFrom
            To         = $MailTo
            Subject    = $Subject
            Body       = $mailBody
            Credential = New-Object System.Management.Automation.PSCredential(
                             $SmtpUser,
                             (ConvertTo-SecureString $SmtpPass -AsPlainText -Force)
                         )
            UseSsl   = $true
            Encoding = [System.Text.Encoding]::UTF8
        }
        Send-MailMessage @MailParams
        Write-Log "メール送信完了 → $MailTo"
    } catch {
        Write-Log "[警告] メール送信失敗: $($_.Exception.Message)"
    }
}

# =============================================
# フェーズ1: バックアップ
# =============================================
Write-Log "===== バックアップ開始 対象DB数: $($Databases.Count) ====="

$backupFailed     = @()   # バックアップ失敗リスト
$backupFailedNames = @()  # 検証スキップ判定用DB名リスト

foreach ($db in $Databases) {
    try {
        $bakDir  = "$BackupRoot\bk_$db"
        $bakPath = "$bakDir\$DayFile.bak"
        $bakName = "完全バックアップ${DayJP}03:00"
        $query = @"
BACKUP DATABASE [$db]
TO DISK = N'$bakPath'
WITH NOFORMAT, INIT, NAME = N'$bakName',
    SKIP, NOREWIND, NOUNLOAD,
    STATS = 10, CHECKSUM, STOP_ON_ERROR
"@
        Write-Log "[情報] バックアップ開始: $db"
        New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
        Invoke-Sqlcmd -ServerInstance $SqlServer -Query $query -QueryTimeout 3600 -ErrorAction Stop
        Write-Log "[成功] バックアップ完了: $db -> $bakPath"

    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "[エラー] バックアップ失敗: $db - $errMsg"
        $backupFailed      += [PSCustomObject]@{ Database = $db; Error = $errMsg }
        $backupFailedNames += $db
    }
}

# =============================================
# フェーズ2: 整合性検証（バックアップ成功分のみ）
# =============================================
Write-Log "===== 整合性検証開始 ====="

$verifyFailed = @()

foreach ($db in $Databases) {

    # バックアップ失敗済みのDBはスキップ
    if ($backupFailedNames -contains $db) {
        Write-Log "[スキップ] バックアップ失敗のため検証をスキップ: $db"
        continue
    }

    try {
        $bakPath = "$BackupRoot\bk_$db\$DayFile.bak"

        $verifyQuery = @"
DECLARE @backupSetId AS INT
SELECT @backupSetId = position
FROM   msdb..backupset
WHERE  database_name = N'$db'
  AND  backup_set_id = (
           SELECT MAX(backup_set_id)
           FROM   msdb..backupset
           WHERE  database_name = N'$db'
       )
IF @backupSetId IS NULL
BEGIN
    RAISERROR(N'確認に失敗しました。データベース ''$db'' のバックアップ情報が見つかりません。', 16, 1)
END
RESTORE VERIFYONLY
FROM  DISK = N'$bakPath'
WITH  FILE = @backupSetId, NOUNLOAD, NOREWIND
"@
        Write-Log "[情報] 整合性検証開始: $db"
        Invoke-Sqlcmd -ServerInstance $SqlServer -Query $verifyQuery -QueryTimeout 3600 -ErrorAction Stop
        Write-Log "[成功] 整合性検証完了: $db"

    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "[エラー] 整合性検証失敗: $db - $errMsg"
        $verifyFailed += [PSCustomObject]@{ Database = $db; Error = $errMsg }
    }
}

# =============================================
# フェーズ3: まとめて通知
# =============================================

# バックアップ失敗通知
if ($backupFailed.Count -gt 0) {
    $failureLines = $backupFailed | ForEach-Object { "  - $($_.Database)`n    エラー: $($_.Error)" }
    $subject = "[要対応] SQLServerバックアップ失敗 ($($backupFailed.Count)件) ($(Get-Date -Format 'yyyy/MM/dd HH:mm'))"
    $body = @"
SQLServerのバックアップが失敗しました。

サーバー    : $SqlServer
発生日時    : $(Get-Date -Format 'yyyy/MM/dd HH:mm:ss')
失敗件数    : $($backupFailed.Count) 件

【失敗したデータベース】
$($failureLines -join "`n")

ログファイル: $LogFile
"@
    Send-Mail -Subject $subject -mailBody $body
}

# 整合性検証失敗通知
if ($verifyFailed.Count -gt 0) {
    $failureLines = $verifyFailed | ForEach-Object { "  - $($_.Database)`n    エラー: $($_.Error)" }
    $subject = "[要対応] SQLServerバックアップ検証失敗 ($($verifyFailed.Count)件) ($(Get-Date -Format 'yyyy/MM/dd HH:mm'))"
    $body = @"
SQLServerのバックアップ整合性検証が失敗しました。
バックアップファイルが破損している可能性があります。至急確認してください。

サーバー    : $SqlServer
発生日時    : $(Get-Date -Format 'yyyy/MM/dd HH:mm:ss')
失敗件数    : $($verifyFailed.Count) 件

【検証失敗したデータベース】
$($failureLines -join "`n")

ログファイル: $LogFile
"@
    Send-Mail -Subject $subject -mailBody $body
}

Write-Log "===== 処理終了 ====="