#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────
# tgmsg.sh - Unified notification (Telegram + Email fallback, parallel Syslog)
#
# Environment Variables:
#   TGMSG_BOT_TOKEN      - Telegram Bot API token
#   TGMSG_CHAT_ID        - Telegram chat/group ID
#   TGMSG_SMTP_HOST      - SMTP server (default: localhost)
#   TGMSG_SMTP_PORT      - SMTP port (default: 25)
#   TGMSG_SMTP_FROM      - Sender address
#   TGMSG_SMTP_TO        - Recipient address
#   TGMSG_SMTP_USER      - SMTP username (optional)
#   TGMSG_SMTP_PASS      - SMTP password (optional)
#   TGMSG_SMTP_USE_TLS   - "true" to enable STARTTLS (default: false)
#   TGMSG_SUBJECT        - Default subject prefix (default: [tgmsg])
#   TGMSG_SYSLOG_HOST    - Syslog server hostname/IP (blank = disabled)
#   TGMSG_SYSLOG_PORT    - Syslog UDP port (default: 514)
#   TGMSG_SYSLOG_LEVEL   - Min priority to send: all, normal, warning, critical
#
# Usage as library:
#   source /usr/local/lib/tgmsg.sh
#   tgmsg "Server is DOWN" critical
#
# Usage standalone:
#   ./tgmsg.sh "Server is DOWN" [silent|normal|warning|critical] ["Subject"]
# ──────────────────────────────────────────────────────────

# Defaults
TGMSG_BOT_TOKEN="${TGMSG_BOT_TOKEN:-}"
TGMSG_CHAT_ID="${TGMSG_CHAT_ID:-}"
TGMSG_SMTP_HOST="${TGMSG_SMTP_HOST:-localhost}"
TGMSG_SMTP_PORT="${TGMSG_SMTP_PORT:-25}"
TGMSG_SMTP_FROM="${TGMSG_SMTP_FROM:-alerts@localhost}"
TGMSG_SMTP_TO="${TGMSG_SMTP_TO:-}"
TGMSG_SMTP_USER="${TGMSG_SMTP_USER:-}"
TGMSG_SMTP_PASS="${TGMSG_SMTP_PASS:-}"
TGMSG_SMTP_USE_TLS="${TGMSG_SMTP_USE_TLS:-false}"
TGMSG_SUBJECT="${TGMSG_SUBJECT:-[tgmsg]}"
TGMSG_SYSLOG_HOST="${TGMSG_SYSLOG_HOST:-}"
TGMSG_SYSLOG_PORT="${TGMSG_SYSLOG_PORT:-514}"
TGMSG_SYSLOG_LEVEL="${TGMSG_SYSLOG_LEVEL:-all}"

# Priority → numeric rank
_priority_rank() {
    case "$1" in
        silent)   echo 0 ;;
        normal)   echo 1 ;;
        warning)  echo 2 ;;
        critical) echo 3 ;;
        all)      echo 0 ;;
        *)        echo 1 ;;
    esac
}

# Priority → syslog severity (RFC 3164)
_syslog_severity() {
    case "$1" in
        silent)   echo 6 ;;   # Informational
        normal)   echo 5 ;;   # Notice
        warning)  echo 4 ;;   # Warning
        critical) echo 2 ;;   # Critical
        *)        echo 5 ;;
    esac
}

# Priority → emoji prefix
_priority_prefix() {
    case "$1" in
        silent)   printf '\xe2\x84\xb9\xef\xb8\x8f' ;;   # ℹ️
        normal)   printf '\xe2\x9c\x85' ;;                 # ✅
        warning)  printf '\xe2\x9a\xa0\xef\xb8\x8f' ;;   # ⚠️
        critical) printf '\xf0\x9f\x94\xa5' ;;             # 🔥
        *)        printf '\xe2\x9c\x85' ;;
    esac
}

# ──────────────────────────────────────────────
# Internal: Send via Syslog (UDP, RFC 3164)
# ──────────────────────────────────────────────
_send_syslog() {
    local message="$1"
    local priority="${2:-normal}"

    if [[ -z "$TGMSG_SYSLOG_HOST" ]]; then
        return 1
    fi

    # Check threshold
    local msg_rank threshold_rank
    msg_rank=$(_priority_rank "$priority")
    threshold_rank=$(_priority_rank "$TGMSG_SYSLOG_LEVEL")

    if [[ "$TGMSG_SYSLOG_LEVEL" != "all" && "$msg_rank" -lt "$threshold_rank" ]]; then
        return 1
    fi

    local severity facility pri timestamp hostname syslog_msg
    severity=$(_syslog_severity "$priority")
    facility=16  # local0
    pri=$(( (facility * 8) + severity ))
    timestamp=$(date +"%b %d %H:%M:%S")
    hostname=$(hostname)

    syslog_msg="<${pri}>${timestamp} ${hostname} tgmsg: [${priority^^}] ${message}"

    # Send UDP — use /dev/udp if available, fall back to nc
    if [[ -e /dev/udp ]]; then
        echo -n "$syslog_msg" > /dev/udp/"${TGMSG_SYSLOG_HOST}"/"${TGMSG_SYSLOG_PORT}" 2>/dev/null
    elif command -v nc &>/dev/null; then
        echo -n "$syslog_msg" | nc -u -w1 "$TGMSG_SYSLOG_HOST" "$TGMSG_SYSLOG_PORT" 2>/dev/null
    elif command -v ncat &>/dev/null; then
        echo -n "$syslog_msg" | ncat -u -w1 "$TGMSG_SYSLOG_HOST" "$TGMSG_SYSLOG_PORT" 2>/dev/null
    else
        echo "[tgmsg] Syslog failed: no /dev/udp or nc/ncat available." >&2
        return 1
    fi

    if [[ $? -eq 0 ]]; then
        echo "[tgmsg] Syslog: sent successfully."
        return 0
    else
        echo "[tgmsg] Syslog failed." >&2
        return 1
    fi
}

# ──────────────────────────────────────────────
# Internal: Send via Telegram
# ──────────────────────────────────────────────
_send_telegram() {
    local message="$1"
    local priority="${2:-normal}"

    if [[ -z "$TGMSG_BOT_TOKEN" || -z "$TGMSG_CHAT_ID" ]]; then
        echo "[tgmsg] Telegram not configured, skipping." >&2
        return 1
    fi

    local prefix silent
    prefix=$(_priority_prefix "$priority")
    case "$priority" in
        silent) silent="true"  ;;
        *)      silent="false" ;;
    esac

    local text="${prefix} ${message}"

    local response http_code body
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

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        echo "[tgmsg] Telegram: sent successfully."
        return 0
    else
        echo "[tgmsg] Telegram failed (HTTP ${http_code}): ${body}" >&2
        return 1
    fi
}

# ──────────────────────────────────────────────
# Internal: Send via Email (curl SMTP)
# ──────────────────────────────────────────────
_send_email() {
    local message="$1"
    local subject="${2:-${TGMSG_SUBJECT} Alert}"
    local priority="${3:-normal}"

    if [[ -z "$TGMSG_SMTP_TO" ]]; then
        echo "[tgmsg] Email not configured (TGMSG_SMTP_TO missing), skipping." >&2
        return 1
    fi

    local timestamp prefix
    timestamp=$(date --iso-8601=seconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")
    prefix=$(_priority_prefix "$priority")

    local email_body
    email_body=$(cat <<EOF
From: ${TGMSG_SMTP_FROM}
To: ${TGMSG_SMTP_TO}
Subject: ${subject}
Date: $(date -R 2>/dev/null || date)
Content-Type: text/plain; charset=UTF-8

${prefix} ${message}

---
Timestamp: ${timestamp}
Priority:  ${priority}
Hostname:  $(hostname)
EOF
    )

    local curl_args=(
        -s --max-time 15
        --url "smtp://${TGMSG_SMTP_HOST}:${TGMSG_SMTP_PORT}"
        --mail-from "$TGMSG_SMTP_FROM"
        --mail-rcpt "$TGMSG_SMTP_TO"
        -T -
    )

    if [[ "$TGMSG_SMTP_USE_TLS" == "true" ]]; then
        curl_args+=(--ssl-reqd)
    fi

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

# ──────────────────────────────────────────────
# Public: Main notification function
# Usage: tgmsg "message" [priority] [subject]
# ──────────────────────────────────────────────
tgmsg() {
    local message="$1"
    local priority="${2:-normal}"
    local subject="${3:-}"

    if [[ -z "$message" ]]; then
        echo "[tgmsg] Error: No message provided." >&2
        return 1
    fi

    # Parallel: Syslog (never blocks delivery)
    _send_syslog "$message" "$priority" &

    # Primary: Telegram
    if _send_telegram "$message" "$priority"; then
        wait 2>/dev/null
        return 0
    fi

    # Fallback: Email
    echo "[tgmsg] Falling back to email..." >&2
    local email_subject="${subject:-${TGMSG_SUBJECT} $(date +%H:%M) - ${priority^^}}"
    if _send_email "$message" "$email_subject" "$priority"; then
        wait 2>/dev/null
        return 0
    fi

    wait 2>/dev/null
    echo "[tgmsg] *** ALL notification channels FAILED ***" >&2
    return 1
}

# ──────────────────────────────────────────────
# CLI entrypoint
# ──────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 \"message\" [silent|normal|warning|critical] [\"Subject Override\"]"
        exit 1
    fi
    tgmsg "$1" "${2:-normal}" "${3:-}"
    exit $?
fi
