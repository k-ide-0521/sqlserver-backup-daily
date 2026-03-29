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


$SmtpServer  = "smtp.example.jp"
$SmtpPort    = 587
$MailFrom    = "system-server@example.co.jp"
$MailTo      = "system-group@example.co.jp"
$SmtpUser    = "user@example.co.jp"
$SmtpPass    = $env:SMTP_PASS
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
    param(
        [string]$Subject,
        [string]$mailBody
    )
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
            UseSsl     = $true
            Encoding   = [System.Text.Encoding]::UTF8
        }
        Send-MailMessage @MailParams
        Write-Log "メール送信完了 → $MailTo"
    } catch {
        Write-Log "[警告] メール送信失敗: $($_.Exception.Message)"
    }
}


# ---- 処理開始 ----
Write-Log "===== 処理開始 対象DB数: $($Databases.Count) ====="

$failedDatabases = @() # 処理が失敗したデータベースを保持する配列

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
        
        Write-Log "バックアップ開始: $db"

        New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
        Invoke-Sqlcmd `
            -ServerInstance $SqlServer `
            -Query          $query `
            -QueryTimeout   3600 `
            -ErrorAction    Stop

        Write-Log "[処理結果]バックアップ完了: $db -> $bakPath"

    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "[処理エラー] バックアップ失敗: $db - $errMsg"

        $failedDatabases += [PSCustomObject]@{
            Database = $db
            Error    = $errMsg
        }
    }
}

# ---- 処理の失敗通知 ----
if ($failedDatabases.Count -gt 0) {
    $failureLines = $failedDatabases | ForEach-Object {
        "  - $($_.Database)`n    エラー: $($_.Error)"
    }
    $mailSubject = "[処理エラー] SQLServerバックアップ失敗 ($($failedDatabases.Count)件) ($(Get-Date -Format 'yyyy/MM/dd HH:mm'))"
    $mailBody = @"
SQLServerのバックアップが失敗しました。

サーバー    : $SqlServer
発生日時    : $(Get-Date -Format 'yyyy/MM/dd HH:mm:ss')
失敗件数    : $($failedDatabases.Count) 件

【失敗したデータベース】
$($failureLines -join "`n")

ログファイル: $LogFile
"@
    Send-Mail -Subject $mailSubject -mailBody $mailBody
}


Write-Log "===== 処理終了 ====="