# tgmsg

## Overview

**tgmsg** is a set of scripts to send a notification from the command line or from inside of a script to Telegram with an email fallback.

The scripts are written in __Python__, __bash__, and __PowerShell__, so there should be one to fit most script or workflow needs. The scripts can be called on the command line or sourced and used inside of scripts.

## Quick Setup Cheatsheet
Set these once on each machine (or in your .env / profile):

### Linux
Add to `/etc/environment` or `~/.bashrc`:

```bash
export TGMSG_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
export TGMSG_CHAT_ID="987654321"
export TGMSG_SMTP_HOST="mail.company.com"
export TGMSG_SMTP_PORT="25"
export TGMSG_SMTP_FROM="alerts@company.com"
export TGMSG_SMTP_TO="user@company.com"
```

### Windows
Set as system environment variables or in your PowerShell profile:

```powershell
[System.Environment]::SetEnvironmentVariable("TGMSG_BOT_TOKEN", "123456789:ABCdefGHIjklMNOpqrsTUVwxyz", "Machine")
[System.Environment]::SetEnvironmentVariable("TGMSG_CHAT_ID", "987654321", "Machine")
[System.Environment]::SetEnvironmentVariable("TGMSG_SMTP_HOST", "mail.company.com", "Machine")
[System.Environment]::SetEnvironmentVariable("TGMSG_SMTP_FROM", "alerts@company.com", "Machine")
[System.Environment]::SetEnvironmentVariable("TGMSG_SMTP_TO", "user@company.com", "Machine")
```
> This method will write to the Registry and persist across reboots.

 Or to set in the user session, like for testing, you can just set them directly:
 ```powershell
$env:TGMSG_BOT_TOKEN = "ABCdefGHIjklMNOpqrsTUVwxyz"
$env:TGMSG_BOT_TOKEN = "987654321"
$env:TGMSG_SMTP_HOST = "mail.company.com"
$env:TGMSG_SMTP_FROM = "alerts@company.com"
$env:TGMSG_SMTP_TO = "user@company.com"
 ```


## Usage

### Python

```python
# As CLI
python3 tgmsg.py "prod-db-01 disk at 95%" --priority critical

# As module in your Flask apps
from tgmsg import tgmsg
tgmsg("*Backup completed*\nHost: `prod-web-03`\nDuration: 12m", priority="normal")
```

### Bash

```bash
# Standalone
./tgmsg.sh "prod-web-03 is DOWN" critical

# As a library (source it from other scripts)
source /usr/local/lib/tgmsg.sh
tgmsg "Backup completed on $(hostname)" silent
tgmsg "*CRITICAL*: RAID degraded on $(hostname)" critical "RAID ALERT"
```

### PowerShell

```powershell
# Standalone
.\Send-TGMsg.ps1 -Message "RAID degraded on FILESVR01" -Priority critical

# Dot-source as a library in other scripts
. C:\Tools\Notify\Send-TGMsg.ps1
Send-TGMsg -Message "Backup completed" -Priority silent
Send-TGMsg -Message "*DISK ALERT*: E: drive at 95%" -Priority critical
```


### Environment Variables

| Variable | Description |
|---|---|
TGMSG_BOT_TOKEN | Telegram Bot API token
TGMSG_CHAT_ID | Telegram chat/group ID
TGMSG_SMTP_HOST | SMTP server (default: localhost)
TGMSG_SMTP_PORT | SMTP port (default: 25)
TGMSG_SMTP_FROM | Sender address
TGMSG_SMTP_TO | Recipient address
TGMSG_SMTP_USER | SMTP username (optional, triggers auth)
TGMSG_SMTP_PASS | SMTP password (optional)
TGMSG_SMTP_USE_TLS | "true" to enable STARTTLS (default: false)
TGMSG_SUBJECT | Default subject prefix (default: [SysAlert])


One-liner to check all environment variables in PowerShell for "User" values:

```powershell
"TGMSG_BOT_TOKEN","TGMSG_CHAT_ID","TGMSG_SMTP_HOST","TGMSG_SMTP_FROM","TGMSG_SMTP_TO" | ForEach-Object {    [PSCustomObject]@{ Variable = $_; Value = [System.Environment]::GetEnvironmentVariable($_, "User") }} | Format-Table -AutoSize
```