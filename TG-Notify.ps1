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
function Get-NotifyConfig {
    @{
        TgToken      = $env:TG_BOT_TOKEN
        TgChatId     = $env:TG_CHAT_ID
        SmtpHost     = if ($env:SMTP_HOST)     { $env:SMTP_HOST }     else { "localhost" }
        SmtpPort     = if ($env:SMTP_PORT)     { [int]$env:SMTP_PORT } else { 25 }
        SmtpFrom     = if ($env:SMTP_FROM)     { $env:SMTP_FROM }     else { "alerts@localhost" }
        SmtpTo       = $env:SMTP_TO
        SmtpUser     = $env:SMTP_USER
        SmtpPass     = $env:SMTP_PASS
        SmtpUseTls   = ($env:SMTP_USE_TLS -eq "true")
        SubjectPfx   = if ($env:NOTIFY_SUBJECT) { $env:NOTIFY_SUBJECT } else { "[SysAlert]" }
    }
}

# Priority mappings
$Script:PriorityMap = @{
    "silent"   = @{ Prefix = "$([char]0x2139)$([char]0xFE0F)";  Silent = $true  }   # ℹ️
    "normal"   = @{ Prefix = "$([char]0x26A0)$([char]0xFE0F)";  Silent = $false }   # ⚠️
    "critical" = @{ Prefix = [char]::ConvertFromUtf32(0x1F525); Silent = $false }   # 🔥
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
        Write-Warning "[notify] Telegram not configured, skipping."
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
            Write-Host "[notify] Telegram: sent successfully."
            return $true
        }
        else {
            Write-Warning "[notify] Telegram API returned unexpected response."
            return $false
        }
    }
    catch {
        Write-Warning "[notify] Telegram failed: $_"
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
        Write-Warning "[notify] Email not configured (SMTP_TO missing), skipping."
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
        Write-Host "[notify] Email: sent successfully."
        return $true
    }
    catch {
        Write-Warning "[notify] Email failed: $_"
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
    Write-Warning "[notify] Falling back to email..."
    $result.Email = Send-EmailFallback -Message $Message -Subject $Subject -Priority $Priority
    $result.Delivered = $result.Email

    if (-not $result.Delivered) {
        Write-Error "[notify] *** ALL notification channels FAILED ***"
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