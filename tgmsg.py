#!/usr/bin/env python3
"""
tgmsg.py - Unified notification module (Telegram + Email fallback)

Environment Variables:
    TGMSG_BOT_TOKEN        - Telegram Bot API token
    TGMSG_CHAT_ID          - Telegram chat/group ID
    TGMSG_SMTP_HOST        - SMTP server (default: localhost)
    TGMSG_SMTP_PORT        - SMTP port (default: 25)
    TGMSG_SMTP_USER        - SMTP username (optional, triggers auth)
    TGMSG_SMTP_PASS        - SMTP password (optional)
    TGMSG_SMTP_FROM        - Sender address
    TGMSG_SMTP_TO          - Recipient address(es), comma-separated
    TGMSG_SMTP_USE_TLS     - "true" to enable STARTTLS (default: false)
    TGMSG_SUBJECT          - Default email subject prefix (default: "[SysAlert]")

Usage as module:
    from tgmsg import notify
    notify("Server is DOWN", priority="critical")

Usage from CLI:
    python3 tgmsg.py "Server is DOWN"
    python3 tgmsg.py "Backup OK" --priority silent
    python3 tgmsg.py "Disk 95%" --priority critical --subject "DISK ALERT"
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

#-----------------------------------------------
# Config from environment
#-----------------------------------------------
TGMSG_BOT_TOKEN = os.environ.get("TGMSG_BOT_TOKEN", "")
TGMSG_CHAT_ID = os.environ.get("TGMSG_CHAT_ID", "")
TGMSG_SMTP_HOST = os.environ.get("TGMSG_SMTP_HOST", "localhost")
TGMSG_SMTP_PORT = int(os.environ.get("TGMSG_SMTP_PORT", "25"))
TGMSG_SMTP_USER = os.environ.get("TGMSG_SMTP_USER", "")
TGMSG_SMTP_PASS = os.environ.get("TGMSG_SMTP_PASS", "")
TGMSG_SMTP_FROM = os.environ.get("TGMSG_SMTP_FROM", "alerts@localhost")
TGMSG_SMTP_TO = os.environ.get("TGMSG_SMTP_TO", "")
TGMSG_SMTP_USE_TLS = os.environ.get("TGMSG_SMTP_USE_TLS", "false").lower() == "true"
SUBJECT_PFX = os.environ.get("TGMSG_SUBJECT", "[SysAlert]")

# Priority → Telegram emoji prefix
PRIORITY_MAP = {
    "silent":   ("ℹ️", True),    # (prefix, disable_notification)
    "normal":   ("⚠️", False),
    "critical": ("🔥", False),
}


def _send_telegram(message: str, priority: str = "normal") -> bool:
    """Send a message via Telegram Bot API. Returns True on success."""
    if not TGMSG_BOT_TOKEN or not TGMSG_CHAT_ID:
        print("[tgmsg] Telegram not configured, skipping.", file=sys.stderr)
        return False

    prefix, silent = PRIORITY_MAP.get(priority, PRIORITY_MAP["normal"])
    text = f"{prefix} {message}"

    payload = json.dumps({
        "chat_id": TGMSG_CHAT_ID,
        "text": text,
        "parse_mode": "Markdown",
        "disable_notification": silent,
    }).encode("utf-8")

    req = urllib.request.Request(
        f"https://api.telegram.org/bot{TGMSG_BOT_TOKEN}/sendMessage",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read())
            if result.get("ok"):
                print("[tgmsg] Telegram: sent successfully.")
                return True
            else:
                print(f"[tgmsg] Telegram API error: {result}", file=sys.stderr)
                return False
    except (urllib.error.URLError, OSError) as e:
        print(f"[tgmsg] Telegram failed: {e}", file=sys.stderr)
        return False


def _send_email(message: str, subject: str = "", priority: str = "normal") -> bool:
    """Send a message via SMTP email. Returns True on success."""
    if not TGMSG_SMTP_TO:
        print("[tgmsg] Email not configured (TGMSG_SMTP_TO missing), skipping.", file=sys.stderr)
        return False

    recipients = [addr.strip() for addr in TGMSG_SMTP_TO.split(",")]
    prefix, _ = PRIORITY_MAP.get(priority, PRIORITY_MAP["normal"])
    subj = subject if subject else f"{SUBJECT_PFX} {prefix} Alert - {priority.upper()}"

    msg = MIMEMultipart("alternative")
    msg["From"]    = TGMSG_SMTP_FROM
    msg["To"]      = ", ".join(recipients)
    msg["Subject"] = subj

    # Plain text body with timestamp
    body = f"{message}\n\n---\nTimestamp: {datetime.now().isoformat()}\nPriority: {priority}"
    msg.attach(MIMEText(body, "plain"))

    try:
        if TGMSG_SMTP_USE_TLS:
            server = smtplib.SMTP(TGMSG_SMTP_HOST, TGMSG_SMTP_PORT, timeout=10)
            server.ehlo()
            server.starttls()
            server.ehlo()
        else:
            server = smtplib.SMTP(TGMSG_SMTP_HOST, TGMSG_SMTP_PORT, timeout=10)

        if TGMSG_SMTP_USER and TGMSG_SMTP_PASS:
            server.login(TGMSG_SMTP_USER, TGMSG_SMTP_PASS)

        server.sendmail(TGMSG_SMTP_FROM, recipients, msg.as_string())
        server.quit()
        print("[tgmsg] Email: sent successfully.")
        return True
    except Exception as e:
        print(f"[tgmsg] Email failed: {e}", file=sys.stderr)
        return False


def tgmsg(message: str, priority: str = "normal", subject: str = "") -> dict:
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
    print("[tgmsg] Falling back to email...", file=sys.stderr)
    result["email"] = _send_email(message, subject, priority)
    result["delivered"] = result["email"]
    if not result["delivered"]:
        print("[tgmsg] *** ALL notification channels FAILED ***", file=sys.stderr)

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

    result = tgmsg(args.message, args.priority, args.subject)

    # Exit code: 0 if delivered, 1 if all channels failed
    sys.exit(0 if result["delivered"] else 1)