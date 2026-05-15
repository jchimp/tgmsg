#!/usr/bin/env python3
"""
tg-notify.py - Unified notification module (Telegram + Email fallback)

Environment Variables:
    TG_BOT_TOKEN    - Telegram Bot API token
    TG_CHAT_ID      - Telegram chat/group ID
    SMTP_HOST        - SMTP server (default: localhost)
    SMTP_PORT        - SMTP port (default: 25)
    SMTP_USER        - SMTP username (optional, triggers auth)
    SMTP_PASS        - SMTP password (optional)
    SMTP_FROM        - Sender address
    SMTP_TO          - Recipient address(es), comma-separated
    SMTP_USE_TLS     - "true" to enable STARTTLS (default: false)
    NOTIFY_SUBJECT   - Default email subject prefix (default: "[SysAlert]")

Usage as module:
    from tg-notify import notify
    notify("Server is DOWN", priority="critical")

Usage from CLI:
    python3 tg-notify.py "Server is DOWN"
    python3 tg-notify.py "Backup OK" --priority silent
    python3 tg-notify.py "Disk 95%" --priority critical --subject "DISK ALERT"
"""

import os
import sys
import json
import smtplib
import argparse
import urllib.request
import urllib.error
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from datetime import datetime

# ──────────────────────────────────────────────
# Config from environment
# ──────────────────────────────────────────────
TG_BOT_TOKEN = os.environ.get("TG_BOT_TOKEN", "")
TG_CHAT_ID   = os.environ.get("TG_CHAT_ID", "")
SMTP_HOST    = os.environ.get("SMTP_HOST", "localhost")
SMTP_PORT    = int(os.environ.get("SMTP_PORT", "25"))
SMTP_USER    = os.environ.get("SMTP_USER", "")
SMTP_PASS    = os.environ.get("SMTP_PASS", "")
SMTP_FROM    = os.environ.get("SMTP_FROM", "alerts@localhost")
SMTP_TO      = os.environ.get("SMTP_TO", "")
SMTP_USE_TLS = os.environ.get("SMTP_USE_TLS", "false").lower() == "true"
SUBJECT_PFX  = os.environ.get("NOTIFY_SUBJECT", "[SysAlert]")

# Priority → Telegram emoji prefix
PRIORITY_MAP = {
    "silent":   ("ℹ️", True),    # (prefix, disable_notification)
    "normal":   ("⚠️", False),
    "critical": ("🔥", False),
}


def _send_telegram(message: str, priority: str = "normal") -> bool:
    """Send a message via Telegram Bot API. Returns True on success."""
    if not TG_BOT_TOKEN or not TG_CHAT_ID:
        print("[notify] Telegram not configured, skipping.", file=sys.stderr)
        return False

    prefix, silent = PRIORITY_MAP.get(priority, PRIORITY_MAP["normal"])
    text = f"{prefix} {message}"

    payload = json.dumps({
        "chat_id": TG_CHAT_ID,
        "text": text,
        "parse_mode": "Markdown",
        "disable_notification": silent,
    }).encode("utf-8")

    req = urllib.request.Request(
        f"https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read())
            if result.get("ok"):
                print("[notify] Telegram: sent successfully.")
                return True
            else:
                print(f"[notify] Telegram API error: {result}", file=sys.stderr)
                return False
    except (urllib.error.URLError, OSError) as e:
        print(f"[notify] Telegram failed: {e}", file=sys.stderr)
        return False


def _send_email(message: str, subject: str = "", priority: str = "normal") -> bool:
    """Send a message via SMTP email. Returns True on success."""
    if not SMTP_TO:
        print("[notify] Email not configured (SMTP_TO missing), skipping.", file=sys.stderr)
        return False

    recipients = [addr.strip() for addr in SMTP_TO.split(",")]
    prefix, _ = PRIORITY_MAP.get(priority, PRIORITY_MAP["normal"])
    subj = subject if subject else f"{SUBJECT_PFX} {prefix} Alert - {priority.upper()}"

    msg = MIMEMultipart("alternative")
    msg["From"]    = SMTP_FROM
    msg["To"]      = ", ".join(recipients)
    msg["Subject"] = subj

    # Plain text body with timestamp
    body = f"{message}\n\n---\nTimestamp: {datetime.now().isoformat()}\nPriority: {priority}"
    msg.attach(MIMEText(body, "plain"))

    try:
        if SMTP_USE_TLS:
            server = smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=10)
            server.ehlo()
            server.starttls()
            server.ehlo()
        else:
            server = smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=10)

        if SMTP_USER and SMTP_PASS:
            server.login(SMTP_USER, SMTP_PASS)

        server.sendmail(SMTP_FROM, recipients, msg.as_string())
        server.quit()
        print("[notify] Email: sent successfully.")
        return True
    except Exception as e:
        print(f"[notify] Email failed: {e}", file=sys.stderr)
        return False


def notify(message: str, priority: str = "normal", subject: str = "") -> dict:
    """
    Send a notification. Tries Telegram first, falls back to email.
    
    Args:
        message:  The alert text (supports Markdown for Telegram)
        priority: "silent", "normal", or "critical"
        subject:  Optional email subject override
    
    Returns:
        dict with 'telegram' and 'email' booleans, plus 'delivered' overall status
    """
    result = {"telegram": False, "email": False, "delivered": False}

    # Primary: Telegram
    result["telegram"] = _send_telegram(message, priority)

    if result["telegram"]:
        result["delivered"] = True
        return result

    # Fallback: Email
    print("[notify] Falling back to email...", file=sys.stderr)
    result["email"] = _send_email(message, subject, priority)
    result["delivered"] = result["email"]

    if not result["delivered"]:
        print("[notify] *** ALL notification channels FAILED ***", file=sys.stderr)

    return result


#-----------------------------------------------
# CLI entrypoint
#-----------------------------------------------
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Send a system notification (Telegram → Email fallback)")
    parser.add_argument("message", help="The notification message text")
    parser.add_argument("--priority", choices=["silent", "normal", "critical"], default="normal")
    parser.add_argument("--subject", default="", help="Override email subject line")
    args = parser.parse_args()

    result = notify(args.message, args.priority, args.subject)

    # Exit code: 0 if delivered, 1 if all channels failed
    sys.exit(0 if result["delivered"] else 1)