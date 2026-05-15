# tg-notify

## Overview

**tg-notify** is a set of scripts to send a notification from the command line or from inside of a script. The scripts are written in __Python__, __bash__, and __PowerShell__, so there should be one to fit most script or workflow needs.

## Quick Setup Cheatsheet
Set these once on each machine (or in your .env / profile):

### Linux
Add to `/etc/environment` or `~/.bashrc`:

```bash
export TG_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
export TG_CHAT_ID="987654321"
export SMTP_HOST="mail.company.com"
export SMTP_PORT="25"
export SMTP_FROM="alerts@company.com"
export SMTP_TO="jchampion@company.com"
```

### Windows
Set as system environment variables or in your PowerShell profile:

```powershell
[System.Environment]::SetEnvironmentVariable("TG_BOT_TOKEN", "123456789:ABCdefGHIjklMNOpqrsTUVwxyz", "Machine")
[System.Environment]::SetEnvironmentVariable("TG_CHAT_ID", "987654321", "Machine")
[System.Environment]::SetEnvironmentVariable("SMTP_HOST", "mail.company.com", "Machine")
[System.Environment]::SetEnvironmentVariable("SMTP_FROM", "alerts@company.com", "Machine")
[System.Environment]::SetEnvironmentVariable("SMTP_TO", "jchampion@company.com", "Machine")
```
> This method will write to the Registry and persist across reboots.

 Or to set in the user session, like for testing, you can just set them directly:
 ```powershell
$env:TG_BOT_TOKEN = "ABCdefGHIjklMNOpqrsTUVwxyz"
$env:TG_BOT_TOKEN = "987654321"
$env:SMTP_HOST = "mail.company.com"
$env:SMTP_FROM = "alerts@company.com"
$env:SMTP_TO = "jchampion@company.com"
 ```


## Usage

### Python

```python
# As CLI
python3 tg-notify.py "prod-db-01 disk at 95%" --priority critical

# As module in your Flask apps
from tg-notify import notify
notify("*Backup completed*\nHost: `prod-web-03`\nDuration: 12m", priority="normal")
```

### Bash

```bash
# Standalone
./tg-notify.sh "prod-web-03 is DOWN" critical

# As a library (source it from other scripts)
source /usr/local/lib/tg-notify.sh
notify "Backup completed on $(hostname)" silent
notify "*CRITICAL*: RAID degraded on $(hostname)" critical "RAID ALERT"
```

### PowerShell

```powershell
# Standalone
.\TG-Notify.ps1 -Message "RAID degraded on FILESVR01" -Priority critical

# Dot-source as a library in other scripts
. C:\Tools\Notify\TG-Notify.ps1
Send-Notification -Message "Backup completed" -Priority silent
Send-Notification -Message "*DISK ALERT*: E: drive at 95%" -Priority critical
```


### Environment Variables

One-liner to check all environment variables in PowerShell:

```powershell
"TG_BOT_TOKEN","TG_CHAT_ID","SMTP_HOST","SMTP_FROM","SMTP_TO" | ForEach-Object {    [PSCustomObject]@{ Variable = $_; Value = [System.Environment]::GetEnvironmentVariable($_, "User") }} | Format-Table -AutoSize
```