#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────
# Unit tests for tgmsg.sh
# Run: bash test_tgmsg.sh
#
# Requires: nc (netcat) for syslog capture tests
# ──────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/tgmsg.sh"

PASS=0
FAIL=0

# ── Test helper ──────────────────────────────
assert_eq() {
    local test_name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: ${test_name}"
        ((PASS++))
    else
        echo "  FAIL: ${test_name} (expected='${expected}', got='${actual}')"
        ((FAIL++))
    fi
}

assert_contains() {
    local test_name="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: ${test_name}"
        ((PASS++))
    else
        echo "  FAIL: ${test_name} (expected to contain '${needle}')"
        ((FAIL++))
    fi
}

# ── Priority Rank Tests ─────────────────────
echo ""
echo "=== Priority Rank Tests ==="

assert_eq "silent rank = 0"   "0" "$(_priority_rank "silent")"
assert_eq "normal rank = 1"   "1" "$(_priority_rank "normal")"
assert_eq "warning rank = 2"  "2" "$(_priority_rank "warning")"
assert_eq "critical rank = 3" "3" "$(_priority_rank "critical")"
assert_eq "all rank = 0"      "0" "$(_priority_rank "all")"
assert_eq "unknown rank = 1"  "1" "$(_priority_rank "bogus")"

# ── Syslog Severity Tests ───────────────────
echo ""
echo "=== Syslog Severity Tests ==="

assert_eq "silent severity = 6"   "6" "$(_syslog_severity "silent")"
assert_eq "normal severity = 5"   "5" "$(_syslog_severity "normal")"
assert_eq "warning severity = 4"  "4" "$(_syslog_severity "warning")"
assert_eq "critical severity = 2" "2" "$(_syslog_severity "critical")"

# ── Priority Prefix Tests ───────────────────
echo ""
echo "=== Priority Prefix Tests ==="

# Just verify each produces a non-empty string
for p in silent normal warning critical; do
    prefix=$(_priority_prefix "$p")
    if [[ -n "$prefix" ]]; then
        echo "  PASS: ${p} prefix is non-empty"
        ((PASS++))
    else
        echo "  FAIL: ${p} prefix is empty"
        ((FAIL++))
    fi
done

# ── Syslog Threshold Tests ──────────────────
echo ""
echo "=== Syslog Threshold Tests ==="

# Test: no host = skip
TGMSG_SYSLOG_HOST=""
TGMSG_SYSLOG_LEVEL="all"
_send_syslog "test" "critical" 2>/dev/null
assert_eq "no host skips syslog" "1" "$?"

# Test: level=critical, priority=normal → skip
TGMSG_SYSLOG_HOST="127.0.0.1"
TGMSG_SYSLOG_PORT="19514"  # non-listening port, we just test threshold logic
TGMSG_SYSLOG_LEVEL="critical"
output=$(_send_syslog "test" "normal" 2>&1)
# Should not contain "sent successfully" since normal < critical
if [[ "$output" != *"sent successfully"* ]]; then
    echo "  PASS: level=critical skips normal"
    ((PASS++))
else
    echo "  FAIL: level=critical should skip normal"
    ((FAIL++))
fi

# Test: level=warning, priority=critical → send
TGMSG_SYSLOG_LEVEL="warning"
output=$(_send_syslog "test" "critical" 2>&1)
assert_contains "level=warning allows critical" "$output" "sent successfully"

# Test: level=all sends everything
TGMSG_SYSLOG_LEVEL="all"
output=$(_send_syslog "test" "silent" 2>&1)
assert_contains "level=all allows silent" "$output" "sent successfully"

# ── Syslog Message Format Tests ─────────────
echo ""
echo "=== Syslog Message Format Tests ==="

# Capture what would be sent using a local UDP listener
if command -v nc &>/dev/null; then
    TGMSG_SYSLOG_HOST="127.0.0.1"
    TGMSG_SYSLOG_PORT="19515"
    TGMSG_SYSLOG_LEVEL="all"

    # Start listener in background
    nc -u -l -p 19515 -w 2 > /tmp/tgmsg_syslog_test.txt 2>/dev/null &
    NC_PID=$!
    sleep 0.3

    _send_syslog "format test message" "critical" >/dev/null 2>&1
    sleep 0.5
    kill $NC_PID 2>/dev/null
    wait $NC_PID 2>/dev/null

    captured=$(cat /tmp/tgmsg_syslog_test.txt 2>/dev/null)
    # PRI for local0 + critical = (16*8)+2 = 130
    assert_contains "syslog has PRI <130>"     "$captured" "<130>"
    assert_contains "syslog has app name"      "$captured" "tgmsg:"
    assert_contains "syslog has priority tag"  "$captured" "[CRITICAL]"
    assert_contains "syslog has message body"  "$captured" "format test message"
    rm -f /tmp/tgmsg_syslog_test.txt
else
    echo "  SKIP: nc not available for format tests"
fi

# ── Telegram Config Tests ───────────────────
echo ""
echo "=== Telegram Config Tests ==="

# Not configured
TGMSG_BOT_TOKEN=""
TGMSG_CHAT_ID=""
output=$(_send_telegram "test" "normal" 2>&1)
assert_contains "no token skips telegram" "$output" "not configured"

# ── Email Config Tests ──────────────────────
echo ""
echo "=== Email Config Tests ==="

TGMSG_SMTP_TO=""
output=$(_send_email "test" "subject" "normal" 2>&1)
assert_contains "no SMTP_TO skips email" "$output" "not configured"

# ── Main Function Tests ─────────────────────
echo ""
echo "=== Main Function (tgmsg) Tests ==="

# No message = error
output=$(tgmsg "" 2>&1)
assert_eq "empty message returns error" "1" "$?"

# All channels unconfigured
TGMSG_BOT_TOKEN=""
TGMSG_CHAT_ID=""
TGMSG_SMTP_TO=""
TGMSG_SYSLOG_HOST=""
output=$(tgmsg "all fail test" "critical" 2>&1)
assert_eq "all channels fail returns 1" "1" "$?"
assert_contains "all fail message shown" "$output" "ALL notification channels FAILED"

# ── Results ──────────────────────────────────
echo ""
echo "================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "================================"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0