# tgmsg

## Overview

**tgmsg** is a set of scripts to send a notification from the command line or from inside of a script to Telegram with an email fallback.

The scripts are written in __Python__, __bash__, and __PowerShell__, so there should be one to fit most script or workflow needs. The scripts can be called on the command line or sourced and used inside of scripts.

## Priority Levels

| Priority | Emoji | Telegram Behavior | Syslog Severity | RFC 3164 Code |
|---|---|---|---|---|
| `silent` | ℹ️ | Silent (no buzz) | Informational | 6 |
| `normal` | ✅ | Normal | Notice | 5 |
| `warning` | ⚠️ | Normal | Warning | 4 |
| `critical` | 🔥 | Normal | Critical | 2 |

### Syslog Threshold Behavior

| `TGMSG_SYSLOG_LEVEL` | Sends to syslog on... |
|---|---|
| `all` | silent, normal, warning, critical |
| `normal` | normal, warning, critical |
| `warning` | warning, critical |
| `critical` | critical only |

---

## Install

Clone the repo. No external dependencies — each script uses only standard library.

```bash
git clone https://github.com/youruser/tgmsg.git
```

### Python
```bash
As a CLI tool
cp tgmsg.py /usr/local/bin/tgmsg
chmod +x /usr/local/bin/tgmsg

# As a module for import
cp tgmsg.py /usr/local/lib/tgmsg.py
```
### Bash
```bash
cp tgmsg.sh /usr/local/lib/tgmsg.sh
chmod +x /usr/local/lib/tgmsg.sh
```
### PowerShell
```powershell
# Standalone
.\Send-TGMsg.ps1 -Message "RAID degraded on FILESVR01" -Priority critical

# Dot-source as a library in other scripts
. C:\Tools\tgmsg\Send-TGMsg.ps1
Send-TGMsg -Message "Backup completed" -Priority silent
Send-TGMsg -Message "*DISK ALERT*: E: drive at 95%" -Priority critical
```


## Telegram Bot Setup

One-time setup, takes about 5 minutes.

1. Create a Bot
    - Open Telegram → search for @BotFather
    - Send /newbot
    - Give it a name (e.g., Ops Alerts) and a username ending in bot (e.g., mycompany_ops_bot)
    - BotFather replies with your Bot Token — looks like: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz

2. Get Your Chat ID
    Open a chat with your new bot and send /start
    Run:
    ```
    curl https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates
    ```
3. Grab `result[0].message.chat.id` from the JSON response (a number like 213456789)
4. Verify It Works:
    ```
    curl -s -X POST "https://api.telegram.org/bot<TOKEN>/sendMessage" \
            -H "Content-Type: application/json" \
            -d '{"chat_id": "<CHAT_ID>", "text": "Hello from tgmsg"}'
    ```

**Group Alerts**
To send to a group: create a group, add the bot, send a message in the group, then use the getUpdates call above to find the group's chat ID (will be a negative number).

---

## Configuration

All config is via environment variables prefixed `TGMSG_`.

| Variable             | Required | Default            | Description                                                 |
| -------------------- | -------- | ------------------ | ----------------------------------------------------------- |
| `TGMSG_BOT_TOKEN`    | Yes      |                    | Telegram Bot API token                                      |
| `TGMSG_CHAT_ID`      | Yes      |                    | Telegram chat or group ID                                   |
| `TGMSG_SMTP_HOST`    | No       | `localhost`        | SMTP server                                                 |
| `TGMSG_SMTP_PORT`    | No       | `25`               | SMTP port                                                   |
| `TGMSG_SMTP_FROM`    | No       | `alerts@localhost` | Sender address                                              |
| `TGMSG_SMTP_TO`      | No       |                    | Recipient(s), comma-separated                               |
| `TGMSG_SMTP_USER`    | No       |                    | SMTP auth username                                          |
| `TGMSG_SMTP_PASS`    | No       |                    | SMTP auth password                                          |
| `TGMSG_SMTP_USE_TLS` | No       | `false`            | `true` to enable STARTTLS                                   |
| `TGMSG_SUBJECT`      | No       | `[tgmsg]`          | Email subject prefix                                        |
| `TGMSG_SYSLOG_HOST`  | No       |                    | Syslog server (blank = disabled)                            |
| `TGMSG_SYSLOG_PORT`  | No       | `514`              | Syslog UDP port                                             |
| `TGMSG_SYSLOG_LEVEL` | No       | `all`              | Min level to syslog: `all`, `normal`, `warning`, `critical` |

### Linux Setup
Add to /etc/environment, ~/.bashrc, or a shared /etc/profile.d/tgmsg.sh:
```
export TGMSG_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
export TGMSG_CHAT_ID="987654321"
export TGMSG_SMTP_HOST="mail.example.com"
export TGMSG_SMTP_PORT="25"
export TGMSG_SMTP_FROM="alerts@example.com"
export TGMSG_SMTP_TO="admin@example.com"
export TGMSG_SYSLOG_HOST="syslog.example.com"
export TGMSG_SYSLOG_PORT="514"
export TGMSG_SYSLOG_LEVEL="warning"
```

### Windows Setup
Set as User-scoped environment variables (no admin required):
```
$vars = @{
    TGMSG_BOT_TOKEN    = "123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
    TGMSG_CHAT_ID      = "987654321"
    TGMSG_SMTP_HOST    = "mail.example.com"
    TGMSG_SMTP_PORT    = "25"
    TGMSG_SMTP_FROM    = "alerts@example.com"
    TGMSG_SMTP_TO      = "admin@example.com"
    TGMSG_SYSLOG_HOST  = "syslog.example.com"
    TGMSG_SYSLOG_PORT  = "514"
    TGMSG_SYSLOG_LEVEL = "warning"
}
$vars.GetEnumerator() | ForEach-Object {
    [System.Environment]::SetEnvironmentVariable($_.Key, $_.Value, "User")
}
```
> Note: Restart your shell after setting variables. Or use "Machine" scope from an elevated prompt for system-wide access.

---

## Usage

### CLI
```
# Python
python3 tgmsg.py "Disk at 95%" --priority critical
python3 tgmsg.py "Backup complete" --priority silent
python3 tgmsg.py "Cert expiring in 7 days" --priority warning --subject "CERT ALERT"

# Bash
./tgmsg.sh "Disk at 95%" critical
./tgmsg.sh "Backup complete" silent
./tgmsg.sh "Cert expiring" warning "CERT ALERT"

# PowerShell
.\Send-TGMsg.ps1 -Message "Disk at 95%" -Priority critical
.\Send-TGMsg.ps1 -Message "Backup complete" -Priority silent
.\Send-TGMsg.ps1 -Message "Cert expiring" -Priority warning -Subject "CERT ALERT"
```

### As a Library
**Python:**
```
from tgmsg import tgmsg

result = tgmsg("Server is DOWN", priority="critical")
# result = {"telegram": True, "email": False, "syslog": True, "delivered": True}

tgmsg("*Backup completed*\nHost: `prod-web-03`\nDuration: 12m", priority="normal")
tgmsg("Routine health check passed", priority="silent")
```

**Bash:**
```
source /usr/local/lib/tgmsg.sh

tgmsg "Backup OK" silent
tgmsg "*CRITICAL*: RAID degraded on $(hostname)" critical "RAID ALERT"
tgmsg "Disk at 90% on $(hostname)" warning
```

**PowerShell:**
```
. C:\Tools\tgmsg\Send-TGMsg.ps1

Send-TGMsg -Message "Backup OK" -Priority silent
Send-TGMsg -Message "RAID degraded on FILESVR01" -Priority critical
Send-TGMsg -Message "Cert expiring in 7 days" -Priority warning
```

### Telegram Markdown

Telegram supports Markdown in messages. Useful for structured alerts:
```shell
python3 tgmsg.py "*CRITICAL*  
_Host:_ prod-db-01  
_Disk:_ 95% full  
_Time:_ $(date)" --priority critical  
```

Renders as:
**CRITICAL** _Host:_ prod-db-01 _Disk:_ 95% full _Time:_ Mon May 12 20:45:00 MDT 2026
