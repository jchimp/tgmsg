#!/usr/bin/env bash
#-------------------------------------------------------------
# tgmsg.sh - Unified notification (Telegram + Email fallback)
#
# Environment Variables:
#   TGMSG_BOT_TOKEN       - Telegram Bot API token
#   TGMSG_CHAT_ID         - Telegram chat/group ID
#   TGMSG_SMTP_HOST       - SMTP server (default: localhost)
#   TGMSG_SMTP_PORT       - SMTP port (default: 25)
#   TGMSG_SMTP_FROM       - Sender address
#   TGMSG_SMTP_TO         - Recipient address
#   TGMSG_SMTP_USER       - SMTP username (optional, triggers auth)
#   TGMSG_SMTP_PASS       - SMTP password (optional)
#   TGMSG_SMTP_USE_TLS    - "true" to enable STARTTLS (default: false)
#   TGMSG_SUBJECT         - Default subject prefix (default: [SysAlert])
#
# Usage as library:
#   source /usr/local/lib/tgmsg.sh
#   notify "Server is DOWN" critical
#
# Usage standalone:
#   ./tgmsg.sh "Server is DOWN" [silent|normal|critical] ["Optional Subject"]
#-------------------------------------------------------------

# Defaults (override via environment)
TGMSG_BOT_TOKEN="${TGMSG_BOT_TOKEN:-}"
TGMSG_CHAT_ID="${TGMSG_CHAT_ID:-}"
TGMSG_SMTP_HOST="${TGMSG_SMTP_HOST:-localhost}"
TGMSG_SMTP_PORT="${TGMSG_SMTP_PORT:-25}"
TGMSG_SMTP_FROM="${TGMSG_SMTP_FROM:-alerts@localhost}"
TGMSG_SMTP_TO="${TGMSG_SMTP_TO:-}"
TGMSG_SMTP_USER="${TGMSG_SMTP_USER:-}"
TGMSG_SMTP_PASS="${TGMSG_SMTP_PASS:-}"
TGMSG_SMTP_USE_TLS="${TGMSG_SMTP_USE_TLS:-false}"
TGMSG_SUBJECT="${TGMSG_SUBJECT:-[SysAlert]}"

# ----------------------------------------------
# Internal: Send via Telegram
# Returns: 0 on success, 1 on failure
# ----------------------------------------------
_send_telegram() {
    local message="$1"
    local priority="${2:-normal}"

    if [[ -z "$TGMSG_BOT_TOKEN" || -z "$TGMSG_CHAT_ID" ]]; then
        echo "[tgmsg] Telegram not configured, skipping." >&2
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
        -X POST "https://api.telegram.org/bot${TGMSG_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$(cat <<EOF
{
    "chat_id": "${TGMSG_CHAT_ID}",
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
        echo "[tgmsg] Telegram: sent successfully."
        return 0
    else
        echo "[tgmsg] Telegram failed (HTTP ${http_code}): ${body}" >&2
        return 1
    fi
}

# ----------------------------------------------
# Internal: Send via Email (curl SMTP)
# Returns: 0 on success, 1 on failure
# ----------------------------------------------
_send_email() {
    local message="$1"
    local subject="${2:-${TGMSG_SUBJECT} Alert}"
    local priority="${3:-normal}"

    if [[ -z "$TGMSG_SMTP_TO" ]]; then
        echo "[tgmsg] Email not configured (TGMSG_SMTP_TO missing), skipping." >&2
        return 1
    fi

    local timestamp
    timestamp=$(date --iso-8601=seconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")

    # Build the email payload
    local email_body
    email_body=$(cat <<EOF
From: ${TGMSG_SMTP_FROM}
To: ${TGMSG_SMTP_TO}
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
        --url "smtp://${TGMSG_SMTP_HOST}:${TGMSG_SMTP_PORT}"
        --mail-from "$TGMSG_SMTP_FROM"
        --mail-rcpt "$TGMSG_SMTP_TO"
        -T -
    )

    # Optional TLS
    if [[ "$TGMSG_SMTP_USE_TLS" == "true" ]]; then
        curl_args+=(--ssl-reqd)
    fi

    # Optional authentication
    if [[ -n "$TGMSG_SMTP_USER" && -n "$TGMSG_SMTP_PASS" ]]; then
        curl_args+=(--user "${TGMSG_SMTP_USER}:${TGMSG_SMTP_PASS}")
    fi

    if echo "$email_body" | curl "${curl_args[@]}" 2>/dev/null; then
        echo "[tgmsg] Email: sent successfully."
        return 0
    else
        echo "[tgmsg] Email failed." >&2
        return 1
    fi
}

# ----------------------------------------------
# Public: Main notification function
# Usage: notify "message" [priority] [subject]
# ----------------------------------------------
tgmsg() {
    local message="$1"
    local priority="${2:-normal}"
    local subject="${3:-}"

    if [[ -z "$message" ]]; then
        echo "[tgmsg] Error: No message provided." >&2
        return 1
    fi

    # Primary: Telegram
    if _send_telegram "$message" "$priority"; then
        return 0
    fi

    # Fallback: Email
    echo "[tgmsg] Falling back to email..." >&2
    local email_subject="${subject:-${TGMSG_SUBJECT} $(date +%H:%M) - ${priority^^}}"
    if _send_email "$message" "$email_subject" "$priority"; then
        return 0
    fi

    echo "[tgmsg] *** ALL notification channels FAILED ***" >&2
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
    tgmsg "$1" "${2:-normal}" "${3:-}"
    exit $?
fi
