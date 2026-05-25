#!/usr/bin/env python3
"""
tgmsg.py - Unified notification module (Telegram + Email fallback, parallel Syslog)

Environment Variables:
    TGMSG_BOT_TOKEN      - Telegram Bot API token
    TGMSG_CHAT_ID        - Telegram chat/group ID
    TGMSG_SMTP_HOST      - SMTP server (default: localhost)
    TGMSG_SMTP_PORT      - SMTP port (default: 25)
    TGMSG_SMTP_USER      - SMTP username (optional, triggers auth)
    TGMSG_SMTP_PASS      - SMTP password (optional)
    TGMSG_SMTP_FROM      - Sender address
    TGMSG_SMTP_TO        - Recipient address(es), comma-separated
    TGMSG_SMTP_USE_TLS   - "true" to enable STARTTLS (default: false)
    TGMSG_SUBJECT        - Default email subject prefix (default: [tgmsg])
    TGMSG_SYSLOG_HOST    - Syslog server hostname/IP (blank = disabled)
    TGMSG_SYSLOG_PORT    - Syslog UDP port (default: 514)
    TGMSG_SYSLOG_LEVEL   - Min priority to send to syslog: all, normal, warning, critical

Usage as module:
    from tgmsg import tgmsg
    tgmsg("Server is DOWN", priority="critical")

Usage from CLI:
    python3 tgmsg.py "Server is DOWN"
    python3 tgmsg.py "Backup OK" --priority silent
    python3 tgmsg.py "Disk 95%" --priority critical --subject "DISK ALERT"
"""

import os
import sys
import json
import socket
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
TG_BOT_TOKEN   = os.environ.get("TGMSG_BOT_TOKEN", "")
TG_CHAT_ID     = os.environ.get("TGMSG_CHAT_ID", "")
SMTP_HOST      = os.environ.get("TGMSG_SMTP_HOST", "localhost")
SMTP_PORT      = int(os.environ.get("TGMSG_SMTP_PORT", "25"))
SMTP_USER      = os.environ.get("TGMSG_SMTP_USER", "")
SMTP_PASS      = os.environ.get("TGMSG_SMTP_PASS", "")
SMTP_FROM      = os.environ.get("TGMSG_SMTP_FROM", "alerts@localhost")
SMTP_TO        = os.environ.get("TGMSG_SMTP_TO", "")
SMTP_USE_TLS   = os.environ.get("TGMSG_SMTP_USE_TLS", "false").lower() == "true"
SUBJECT_PFX    = os.environ.get("TGMSG_SUBJECT", "[tgmsg]")
SYSLOG_HOST    = os.environ.get("TGMSG_SYSLOG_HOST", "")
SYSLOG_PORT    = int(os.environ.get("TGMSG_SYSLOG_PORT", "514"))
SYSLOG_LEVEL   = os.environ.get("TGMSG_SYSLOG_LEVEL", "all").lower()

SYSLOG_FACILITY = 16  # local0

# Priority hierarchy (lowest -> highest)
PRIORITY_ORDER = {"silent": 0, "normal": 1, "warning": 2, "critical": 3}

# Priority -> Telegram emoji prefix, syslog severity
PRIORITY_MAP = {
    "silent":   {"prefix": "\u2139\uFE0F",  "silent": True,  "syslog_severity": 6},     # ℹ️ Informational
    "normal":   {"prefix": "\u2705",        "silent": False, "syslog_severity": 5},     # ✅ Notice
    "warning":  {"prefix": "\u26A0\uFE0F",  "silent": False, "syslog_severity": 4},     # ⚠️ Warning
    "critical": {"prefix": "\U0001F525",    "silent": False, "syslog_severity": 2},     # 🔥 Critical
}


def _should_syslog(priority: str) -> bool:
    """Check if the message priority meets the syslog threshold."""
    if not SYSLOG_HOST:
        return False
    if SYSLOG_LEVEL == "all":
        return True
    threshold = PRIORITY_ORDER.get(SYSLOG_LEVEL, 0)
    current = PRIORITY_ORDER.get(priority, 0)
    return current >= threshold


def _send_syslog(message: str, priority: str = "normal") -> bool:
    """Send a message to syslog via UDP (RFC 3164). Returns True on success."""
    if not _should_syslog(priority):
        return False

    prio = PRIORITY_MAP.get(priority, PRIORITY_MAP["normal"])
    pri = (SYSLOG_FACILITY * 8) + prio["syslog_severity"]
    timestamp = datetime.now().strftime("%b %d %H:%M:%S")
    hostname = socket.gethostname()

    # RFC 3164: <PRI>TIMESTAMP HOSTNAME APP-NAME: MESSAGE
    syslog_msg = f"<{pri}>{timestamp} {hostname} tgmsg: [{priority.upper()}] {message}"

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(5)
        sock.sendto(syslog_msg.encode("utf-8"), (SYSLOG_HOST, SYSLOG_PORT))
        sock.close()
        print("[tgmsg] Syslog: sent successfully.")
        return True
    except OSError as e:
        print(f"[tgmsg] Syslog failed: {e}", file=sys.stderr)
        return False


def _send_telegram(message: str, priority: str = "normal") -> bool:
    """Send a message via Telegram Bot API. Returns True on success."""
    if not TG_BOT_TOKEN or not TG_CHAT_ID:
        print("[tgmsg] Telegram not configured, skipping.", file=sys.stderr)
        return False

    prio = PRIORITY_MAP.get(priority, PRIORITY_MAP["normal"])
    text = f"{prio['prefix']} {message}"

    payload = json.dumps({
        "chat_id": TG_CHAT_ID,
        "text": text,
        "parse_mode": "Markdown",
        "disable_notification": prio["silent"],
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
    if not SMTP_TO:
        print("[tgmsg] Email not configured (TGMSG_SMTP_TO missing), skipping.", file=sys.stderr)
        return False

    recipients = [addr.strip() for addr in SMTP_TO.split(",")]
    prio = PRIORITY_MAP.get(priority, PRIORITY_MAP["normal"])
    subj = subject if subject else f"{SUBJECT_PFX} {prio['prefix']} Alert - {priority.upper()}"

    msg = MIMEMultipart("alternative")
    msg["From"]    = SMTP_FROM
    msg["To"]      = ", ".join(recipients)
    msg["Subject"] = subj

    body = f"{message}\n\n---\nTimestamp: {datetime.now().isoformat()}\nPriority: {priority}"
    msg.attach(MIMEText(body, "plain", "utf-8"))

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
        print("[tgmsg] Email: sent successfully.")
        return True
    except Exception as e:
        print(f"[tgmsg] Email failed: {e}", file=sys.stderr)
        return False


def tgmsg(message: str, priority: str = "normal", subject: str = "") -> dict:
    """
    Send a notification. Syslog fires in parallel. Telegram is primary, email is fallback.

    Args:
        message:  The alert text (supports Markdown for Telegram)
        priority: "silent", "normal", "warning", or "critical"
        subject:  Optional email subject override

    Returns:
        dict with 'telegram', 'email', 'syslog' booleans, plus 'delivered' overall status
    """
    result = {"telegram": False, "email": False, "syslog": False, "delivered": False}

    # Parallel: Syslog (never blocks delivery)
    result["syslog"] = _send_syslog(message, priority)

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


# ──────────────────────────────────────────────
# CLI entrypoint
# ──────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Send a system notification (Telegram + Email fallback, parallel Syslog)")
    parser.add_argument("message", help="The notification message text")
    parser.add_argument("--priority", choices=["silent", "normal", "warning", "critical"], default="normal")
    parser.add_argument("--subject", default="", help="Override email subject line")
    args = parser.parse_args()

    result = tgmsg(args.message, args.priority, args.subject)
    sys.exit(0 if result["delivered"] else 1)