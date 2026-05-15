<#
.SYNOPSIS
    Unified notification module (Telegram + Email fallback)

.DESCRIPTION
    Sends alerts via Telegram Bot API with automatic email fallback.
    All config is driven by environment variables.

.PARAMETER Message
    The notification text (supports Markdown for Telegram)

.PARAMETER Priority
    silent, normal, or critical (default: normal)

.PARAMETER Subject
    Optional email subject override

.EXAMPLE
    # Standalone
    .\TG-Notify.ps1 -Message "Server is DOWN" -Priority critical

.EXAMPLE
    # Dot-source as a library
    . C:\Tools\Notify\TG-Notify.ps1
    Send-Notification -Message "Backup OK" -Priority silent

.NOTES
    Environment Variables:
        TG_BOT_TOKEN, TG_CHAT_ID
        SMTP_HOST, SMTP_PORT, SMTP_FROM, SMTP_TO
        SMTP_USER, SMTP_PASS, SMTP_USE_TLS
        NOTIFY_SUBJECT
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Message,

    [Parameter(Position = 1)]
    [ValidateSet("silent", "normal", "critical")]
    [string]$Priority = "normal",

    [Parameter(Position = 2)]
    [string]$Subject = ""
)

# ----------------------------------------------
# Config from environment
# ----------------------------------------------
function Get-EnvVar {
    param([string]$Name, [string]$Default = "")

    $val = [System.Environment]::GetEnvironmentVariable($Name, "Process")
    if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($Name, "User") }
    if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($Name, "Machine") }
    if (-not $val) { $val = $Default }
    
    return $val
}

function Get-NotifyConfig {
    @{
        TgToken    = (Get-EnvVar -Name "TG_BOT_TOKEN")
        TgChatId   = (Get-EnvVar -Name "TG_CHAT_ID")
        SmtpHost   = (Get-EnvVar -Name "SMTP_HOST" -Default "localhost")
        SmtpPort   = [int](Get-EnvVar -Name "SMTP_PORT" -Default "25")
        SmtpFrom   = (Get-EnvVar -Name "SMTP_FROM" -Default "alerts@localhost")
        SmtpTo     = (Get-EnvVar -Name "SMTP_TO")
        SmtpUser   = (Get-EnvVar -Name "SMTP_USER")
        SmtpPass   = (Get-EnvVar -Name "SMTP_PASS")
        SmtpUseTls = ((Get-EnvVar -Name "SMTP_USE_TLS" -Default "false") -eq "true")
        SubjectPfx = (Get-EnvVar -Name "NOTIFY_SUBJECT" -Default "[SysAlert]")
    }
}

# Priority mappings
$Script:PriorityMap = @{
    "silent"   = @{ Prefix = [System.Char]::ConvertFromUtf32(0x2139);  Silent = $true  }
    "normal"   = @{ Prefix = [System.Char]::ConvertFromUtf32(0x26A0);  Silent = $false }
    "critical" = @{ Prefix = [System.Char]::ConvertFromUtf32(0x1F525); Silent = $false }
}


# ----------------------------------------------
# Internal: Send via Telegram
# ----------------------------------------------
function Send-Telegram {
    param(
        [string]$Message,
        [string]$Priority = "normal"
    )

    $cfg = Get-NotifyConfig
    if (-not $cfg.TgToken -or -not $cfg.TgChatId) {
        Write-Warning "[tg-notify] Telegram not configured, skipping."
        return $false
    }

    $prio   = $Script:PriorityMap[$Priority]
    $text   = "$($prio.Prefix) $Message"
    $body = @{
        chat_id              = $cfg.TgChatId
        text                 = $text
        parse_mode           = "Markdown"
        disable_notification = $prio.Silent
    } | ConvertTo-Json -Depth 3

    try {
        $response = Invoke-RestMethod `
            -Uri "https://api.telegram.org/bot$($cfg.TgToken)/sendMessage" `
            -Method Post `
            -ContentType "application/json; charset=utf-8" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
            -TimeoutSec 10 `
            -ErrorAction Stop

        if ($response.ok -eq $true) {
            Write-Host "[tg-notify] Telegram: sent successfully."
            return $true
        }
        else {
            Write-Warning "[tg-notify] Telegram API returned unexpected response."
            return $false
        }
    }
    catch {
        Write-Warning "[tg-notify] Telegram failed: $_"
        return $false
    }
}

# ----------------------------------------------
# Internal: Send via Email
# ----------------------------------------------
function Send-EmailFallback {
    param(
        [string]$Message,
        [string]$Subject = "",
        [string]$Priority = "normal"
    )

    $cfg = Get-NotifyConfig
    if (-not $cfg.SmtpTo) {
        Write-Warning "[tg-notify] Email not configured (SMTP_TO missing), skipping."
        return $false
    }

    $prio = $Script:PriorityMap[$Priority]
    $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"
    If ($env:COMPUTERNAME) {
        $hostname = $env:COMPUTERNAME    
    }
    else {
        $hostname = $(hostname)
    }
    
    if (-not $Subject) {
        $Subject = "$($cfg.SubjectPfx) $($prio.Prefix) Alert - $($Priority.ToUpper())"
    }

    $emailBody = @"
$Message

---
Timestamp: $timestamp
Priority:  $Priority
Hostname:  $hostname
"@

    $recipients = $cfg.SmtpTo -split "," | ForEach-Object { $_.Trim() }
    $mailParams = @{
        From       = $cfg.SmtpFrom
        To         = $recipients
        Subject    = $Subject
        Body       = $emailBody
        SmtpServer = $cfg.SmtpHost
        Port       = $cfg.SmtpPort
        Encoding   = [System.Text.Encoding]::UTF8
    }

    # Optional TLS
    if ($cfg.SmtpUseTls) {
        $mailParams["UseSsl"] = $true
    }

    # Optional credentials
    if ($cfg.SmtpUser -and $cfg.SmtpPass) {
        $secPass = ConvertTo-SecureString $cfg.SmtpPass -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($cfg.SmtpUser, $secPass)
        $mailParams["Credential"] = $cred
    }

    try {
        Send-MailMessage @mailParams -ErrorAction Stop
        Write-Host "[tg-notify] Email: sent successfully."
        return $true
    }
    catch {
        Write-Warning "[tg-notify] Email failed: $_"
        return $false
    }
}

# ----------------------------------------------
# Public: Main notification function
# ----------------------------------------------
function Send-Notification {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("silent", "normal", "critical")]
        [string]$Priority = "normal",

        [string]$Subject = ""
    )

    $result = @{
        Telegram  = $false
        Email     = $false
        Delivered = $false
    }

    # Primary: Telegram
    $result.Telegram = Send-Telegram -Message $Message -Priority $Priority
    if ($result.Telegram) {
        $result.Delivered = $true
        return [PSCustomObject]$result
    }

    # Fallback: Email
    Write-Warning "[tg-notify] Falling back to email..."
    $result.Email = Send-EmailFallback -Message $Message -Subject $Subject -Priority $Priority
    $result.Delivered = $result.Email
    if (-not $result.Delivered) {
        Write-Error "[tg-notify] *** ALL notification channels FAILED ***"
    }

    return [PSCustomObject]$result
}

# ----------------------------------------------
# CLI entrypoint (runs if called directly)
# ----------------------------------------------
if ($Message) {
    $result = Send-Notification -Message $Message -Priority $Priority -Subject $Subject
    if (-not $result.Delivered) { exit 1 }
}