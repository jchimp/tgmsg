<#
.SYNOPSIS
    Send-TGMsg - Unified notification module (Telegram + Email fallback, parallel Syslog)

.DESCRIPTION
    Sends alerts via Telegram Bot API with automatic email fallback.
    Syslog messages are sent via UDP (RFC 3164) before the Telegram/Email chain.
    All config is driven by environment variables prefixed TGMSG_*.

.PARAMETER Message
    The notification text (supports Markdown for Telegram)

.PARAMETER Priority
    silent, normal, warning, or critical (default: normal)

.PARAMETER Subject
    Optional email subject override

.EXAMPLE
    .\Send-TGMsg.ps1 -Message "Server is DOWN" -Priority critical

.EXAMPLE
    . C:\Tools\tgmsg\Send-TGMsg.ps1
    Send-TGMsg -Message "Backup OK" -Priority silent

.NOTES
    Environment Variables:
        TGMSG_BOT_TOKEN, TGMSG_CHAT_ID
        TGMSG_SMTP_HOST, TGMSG_SMTP_PORT, TGMSG_SMTP_FROM, TGMSG_SMTP_TO
        TGMSG_SMTP_USER, TGMSG_SMTP_PASS, TGMSG_SMTP_USE_TLS
        TGMSG_SUBJECT
        TGMSG_SYSLOG_HOST, TGMSG_SYSLOG_PORT, TGMSG_SYSLOG_LEVEL
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Message,

    [Parameter(Position = 1)]
    [ValidateSet("silent", "normal", "warning", "critical")]
    [string]$Priority = "normal",

    [Parameter(Position = 2)]
    [string]$Subject = ""
)

# ──────────────────────────────────────────────
# Env helper: Process → User → Machine → Default
# ──────────────────────────────────────────────
function Get-EnvVar {
    param([string]$Name, [string]$Default = "")
    $val = [System.Environment]::GetEnvironmentVariable($Name, "Process")
    if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($Name, "User") }
    if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($Name, "Machine") }
    if (-not $val) { $val = $Default }
    return $val
}

function Get-Config {
    @{
        TgToken    = (Get-EnvVar -Name "TGMSG_BOT_TOKEN")
        TgChatId   = (Get-EnvVar -Name "TGMSG_CHAT_ID")
        SmtpHost   = (Get-EnvVar -Name "TGMSG_SMTP_HOST"    -Default "localhost")
        SmtpPort   = (Get-EnvVar -Name "TGMSG_SMTP_PORT"    -Default "25")
        SmtpFrom   = (Get-EnvVar -Name "TGMSG_SMTP_FROM"    -Default "alerts@localhost")
        SmtpTo     = (Get-EnvVar -Name "TGMSG_SMTP_TO")
        SmtpUser   = (Get-EnvVar -Name "TGMSG_SMTP_USER")
        SmtpPass   = (Get-EnvVar -Name "TGMSG_SMTP_PASS")
        SmtpUseTls = ((Get-EnvVar -Name "TGMSG_SMTP_USE_TLS" -Default "false") -eq "true")
        SubjectPfx = (Get-EnvVar -Name "TGMSG_SUBJECT"       -Default "[tgmsg]")
        SyslogHost = (Get-EnvVar -Name "TGMSG_SYSLOG_HOST")
        SyslogPort = (Get-EnvVar -Name "TGMSG_SYSLOG_PORT"   -Default "514")
        SyslogLevel = (Get-EnvVar -Name "TGMSG_SYSLOG_LEVEL" -Default "all").ToLower()
    }
}

# ──────────────────────────────────────────────
# Priority mappings
# ──────────────────────────────────────────────
$Script:PriorityMap = @{
    "silent"   = @{ Prefix = [System.Char]::ConvertFromUtf32(0x2139);  Silent = $true;  Rank = 0; SyslogSeverity = 6 }
    "normal"   = @{ Prefix = [System.Char]::ConvertFromUtf32(0x2705);  Silent = $false; Rank = 1; SyslogSeverity = 5 }
    "warning"  = @{ Prefix = [System.Char]::ConvertFromUtf32(0x26A0);  Silent = $false; Rank = 2; SyslogSeverity = 4 }
    "critical" = @{ Prefix = [System.Char]::ConvertFromUtf32(0x1F525); Silent = $false; Rank = 3; SyslogSeverity = 2 }
}

$Script:LevelRank = @{ "all" = 0; "normal" = 1; "warning" = 2; "critical" = 3 }

# ──────────────────────────────────────────────
# Internal: Send via Syslog (UDP, RFC 3164)
# ──────────────────────────────────────────────
function Send-Syslog {
    param(
        [string]$Message,
        [string]$Priority = "normal"
    )

    $cfg = Get-Config

    if (-not $cfg.SyslogHost) { return $false }

    # Check threshold
    $msgRank       = $Script:PriorityMap[$Priority].Rank
    $thresholdRank = $Script:LevelRank[$cfg.SyslogLevel]
    if ($null -eq $thresholdRank) { $thresholdRank = 0 }

    if ($cfg.SyslogLevel -ne "all" -and $msgRank -lt $thresholdRank) {
        return $false
    }

    $prio      = $Script:PriorityMap[$Priority]
    $facility  = 16  # local0
    $pri       = ($facility * 8) + $prio.SyslogSeverity
    $timestamp = (Get-Date).ToString("MMM dd HH:mm:ss")
    $hostname  = $env:COMPUTERNAME ?? $(hostname)

    $syslogMsg = "<${pri}>${timestamp} ${hostname} tgmsg: [$($Priority.ToUpper())] ${Message}"
    $bytes     = [System.Text.Encoding]::UTF8.GetBytes($syslogMsg)

    try {
        $udpClient = New-Object System.Net.Sockets.UdpClient
        $udpClient.Connect($cfg.SyslogHost, [int]$cfg.SyslogPort)
        [void]$udpClient.Send($bytes, $bytes.Length)
        $udpClient.Close()
        Write-Host "[tgmsg] Syslog: sent successfully."
        return $true
    }
    catch {
        Write-Warning "[tgmsg] Syslog failed: $_"
        return $false
    }
}

# ──────────────────────────────────────────────
# Internal: Send via Telegram
# ──────────────────────────────────────────────
function Send-Telegram {
    param(
        [string]$Message,
        [string]$Priority = "normal"
    )

    $cfg = Get-Config

    if (-not $cfg.TgToken -or -not $cfg.TgChatId) {
        Write-Warning "[tgmsg] Telegram not configured, skipping."
        return $false
    }

    $prio = $Script:PriorityMap[$Priority]
    $text = "$($prio.Prefix) $Message"

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
            Write-Host "[tgmsg] Telegram: sent successfully."
            return $true
        }
        else {
            Write-Warning "[tgmsg] Telegram API returned unexpected response."
            return $false
        }
    }
    catch {
        Write-Warning "[tgmsg] Telegram failed: $_"
        return $false
    }
}

# ──────────────────────────────────────────────
# Internal: Send via Email
# ──────────────────────────────────────────────
function Send-EmailFallback {
    param(
        [string]$Message,
        [string]$Subject = "",
        [string]$Priority = "normal"
    )

    $cfg = Get-Config

    if (-not $cfg.SmtpTo) {
        Write-Warning "[tgmsg] Email not configured (TGMSG_SMTP_TO missing), skipping."
        return $false
    }

    $prio      = $Script:PriorityMap[$Priority]
    $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"
    $hostname  = $env:COMPUTERNAME ?? $(hostname)

    if (-not $Subject) {
        $Subject = "$($cfg.SubjectPfx) $($prio.Prefix) Alert - $($Priority.ToUpper())"
    }

    $emailBody = @"
$($prio.Prefix) $Message

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
        Port       = [int]$cfg.SmtpPort
        Encoding   = [System.Text.Encoding]::UTF8
    }

    if ($cfg.SmtpUseTls) {
        $mailParams["UseSsl"] = $true
    }

    if ($cfg.SmtpUser -and $cfg.SmtpPass) {
        $secPass = ConvertTo-SecureString $cfg.SmtpPass -AsPlainText -Force
        $cred    = New-Object System.Management.Automation.PSCredential($cfg.SmtpUser, $secPass)
        $mailParams["Credential"] = $cred
    }

    try {
        Send-MailMessage @mailParams -ErrorAction Stop
        Write-Host "[tgmsg] Email: sent successfully."
        return $true
    }
    catch {
        Write-Warning "[tgmsg] Email failed: $_"
        return $false
    }
}

# ──────────────────────────────────────────────
# Public: Main notification function
# ──────────────────────────────────────────────
function Send-TGMsg {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("silent", "normal", "warning", "critical")]
        [string]$Priority = "normal",

        [string]$Subject = ""
    )

    $result = @{
        Telegram  = $false
        Email     = $false
        Syslog    = $false
        Delivered = $false
    }

    # Syslog first — UDP send is fire-and-forget (~1ms), never blocks delivery
    $result.Syslog = Send-Syslog -Message $Message -Priority $Priority

    # Primary: Telegram
    $result.Telegram = Send-Telegram -Message $Message -Priority $Priority

    if ($result.Telegram) {
        $result.Delivered = $true
        return [PSCustomObject]$result
    }

    # Fallback: Email
    Write-Warning "[tgmsg] Falling back to email..."
    $result.Email = Send-EmailFallback -Message $Message -Subject $Subject -Priority $Priority
    $result.Delivered = $result.Email

    if (-not $result.Delivered) {
        Write-Error "[tgmsg] *** ALL notification channels FAILED ***"
    }

    return [PSCustomObject]$result
}

# ──────────────────────────────────────────────
# CLI entrypoint
# ──────────────────────────────────────────────
if ($Message) {
    $result = Send-TGMsg -Message $Message -Priority $Priority -Subject $Subject
    if (-not $result.Delivered) { exit 1 }
}
