#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────
# tg-notify.sh - Unified notification (Telegram + Email fallback)
#
# Environment Variables:
#   TG_BOT_TOKEN    - Telegram Bot API token
#   TG_CHAT_ID      - Telegram chat/group ID
#   SMTP_HOST       - SMTP server (default: localhost)
#   SMTP_PORT       - SMTP port (default: 25)
#   SMTP_FROM       - Sender address
#   SMTP_TO         - Recipient address
#   SMTP_USER       - SMTP username (optional, triggers auth)
#   SMTP_PASS       - SMTP password (optional)
#   SMTP_USE_TLS    - "true" to enable STARTTLS (default: false)
#   NOTIFY_SUBJECT  - Default subject prefix (default: [SysAlert])
#
# Usage as library:
#   source /usr/local/lib/tg-notify.sh
#   notify "Server is DOWN" critical
#
# Usage standalone:
#   ./tg-notify.sh "Server is DOWN" [silent|normal|critical] ["Optional Subject"]
# ──────────────────────────────────────────────────────────

# Defaults (override via environment)
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
SMTP_HOST="${SMTP_HOST:-localhost}"
SMTP_PORT="${SMTP_PORT:-25}"
SMTP_FROM="${SMTP_FROM:-alerts@localhost}"
SMTP_TO="${SMTP_TO:-}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"
SMTP_USE_TLS="${SMTP_USE_TLS:-false}"
NOTIFY_SUBJECT="${NOTIFY_SUBJECT:-[SysAlert]}"

# ----------------------------------------------
# Internal: Send via Telegram
# Returns: 0 on success, 1 on failure
# ----------------------------------------------
_send_telegram() {
    local message="$1"
    local priority="${2:-normal}"

    if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
        echo "[tg-notify] Telegram not configured, skipping." >&2
        return 1
    fi

    local prefix silent
    case "$priority" in
        silent)   prefix="ℹ️";  silent="true"  ;;
        critical) prefix="🔥"; silent="false" ;;
        *)        prefix="⚠️";  silent="false" ;;
    esac

    local text="${prefix} ${message}"

    local response
    response=$(curl -s -w "\n%{http_code}" --max-time 10 \
        -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$(cat <<EOF
{
    "chat_id": "${TG_CHAT_ID}",
    "text": "${text}",
    "parse_mode": "Markdown",
    "disable_notification": ${silent}
}
EOF
        )" 2>/dev/null)

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        echo "[tg-notify] Telegram: sent successfully."
        return 0
    else
        echo "[tg-notify] Telegram failed (HTTP ${http_code}): ${body}" >&2
        return 1
    fi
}

# ----------------------------------------------
# Internal: Send via Email (curl SMTP)
# Returns: 0 on success, 1 on failure
# ----------------------------------------------
_send_email() {
    local message="$1"
    local subject="${2:-${NOTIFY_SUBJECT} Alert}"
    local priority="${3:-normal}"

    if [[ -z "$SMTP_TO" ]]; then
        echo "[tg-notify] Email not configured (SMTP_TO missing), skipping." >&2
        return 1
    fi

    local timestamp
    timestamp=$(date --iso-8601=seconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")

    # Build the email payload
    local email_body
    email_body=$(cat <<EOF
From: ${SMTP_FROM}
To: ${SMTP_TO}
Subject: ${subject}
Date: $(date -R 2>/dev/null || date)
Content-Type: text/plain; charset=UTF-8

${message}

---
Timestamp: ${timestamp}
Priority:  ${priority}
Hostname:  $(hostname)
EOF
    )

    # Build curl SMTP arguments
    local curl_args=(
        -s --max-time 15
        --url "smtp://${SMTP_HOST}:${SMTP_PORT}"
        --mail-from "$SMTP_FROM"
        --mail-rcpt "$SMTP_TO"
        -T -
    )

    # Optional TLS
    if [[ "$SMTP_USE_TLS" == "true" ]]; then
        curl_args+=(--ssl-reqd)
    fi

    # Optional authentication
    if [[ -n "$SMTP_USER" && -n "$SMTP_PASS" ]]; then
        curl_args+=(--user "${SMTP_USER}:${SMTP_PASS}")
    fi

    if echo "$email_body" | curl "${curl_args[@]}" 2>/dev/null; then
        echo "[tg-notify] Email: sent successfully."
        return 0
    else
        echo "[tg-notify] Email failed." >&2
        return 1
    fi
}

# ----------------------------------------------
# Public: Main notification function
# Usage: notify "message" [priority] [subject]
# ----------------------------------------------
notify() {
    local message="$1"
    local priority="${2:-normal}"
    local subject="${3:-}"

    if [[ -z "$message" ]]; then
        echo "[tg-notify] Error: No message provided." >&2
        return 1
    fi

    # Primary: Telegram
    if _send_telegram "$message" "$priority"; then
        return 0
    fi

    # Fallback: Email
    echo "[tg-notify] Falling back to email..." >&2
    local email_subject="${subject:-${NOTIFY_SUBJECT} $(date +%H:%M) - ${priority^^}}"
    if _send_email "$message" "$email_subject" "$priority"; then
        return 0
    fi

    echo "[tg-notify] *** ALL notification channels FAILED ***" >&2
    return 1
}

# ----------------------------------------------
# CLI entrypoint
# ----------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 \"message\" [silent|normal|critical] [\"Subject Override\"]"
        exit 1
    fi
    notify "$1" "${2:-normal}" "${3:-}"
    exit $?
fi
