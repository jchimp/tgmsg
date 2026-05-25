#!/usr/bin/env python3
"""
Unit tests for tgmsg.py
Run: python3 -m pytest test_tgmsg.py -v
"""

import os
import json
import socket
import unittest
from unittest.mock import patch, MagicMock

# Set test env vars before importing tgmsg
os.environ["TGMSG_BOT_TOKEN"]    = "111111:AAAA-test-token"
os.environ["TGMSG_CHAT_ID"]      = "999999"
os.environ["TGMSG_SMTP_HOST"]    = "localhost"
os.environ["TGMSG_SMTP_PORT"]    = "25"
os.environ["TGMSG_SMTP_FROM"]    = "test@localhost"
os.environ["TGMSG_SMTP_TO"]      = "admin@localhost"
os.environ["TGMSG_SYSLOG_HOST"]  = "127.0.0.1"
os.environ["TGMSG_SYSLOG_PORT"]  = "1514"
os.environ["TGMSG_SYSLOG_LEVEL"] = "all"

import tgmsg


class TestPriorityConfig(unittest.TestCase):
    """Verify priority maps and hierarchy are correct."""

    def test_priority_order_values(self):
        self.assertEqual(tgmsg.PRIORITY_ORDER["silent"],   0)
        self.assertEqual(tgmsg.PRIORITY_ORDER["normal"],   1)
        self.assertEqual(tgmsg.PRIORITY_ORDER["warning"],  2)
        self.assertEqual(tgmsg.PRIORITY_ORDER["critical"], 3)

    def test_all_priorities_have_map_entry(self):
        for p in ["silent", "normal", "warning", "critical"]:
            self.assertIn(p, tgmsg.PRIORITY_MAP)
            self.assertIn("prefix", tgmsg.PRIORITY_MAP[p])
            self.assertIn("silent", tgmsg.PRIORITY_MAP[p])
            self.assertIn("syslog_severity", tgmsg.PRIORITY_MAP[p])

    def test_syslog_severity_values(self):
        self.assertEqual(tgmsg.PRIORITY_MAP["silent"]["syslog_severity"],   6)
        self.assertEqual(tgmsg.PRIORITY_MAP["normal"]["syslog_severity"],   5)
        self.assertEqual(tgmsg.PRIORITY_MAP["warning"]["syslog_severity"],  4)
        self.assertEqual(tgmsg.PRIORITY_MAP["critical"]["syslog_severity"], 2)


class TestShouldSyslog(unittest.TestCase):
    """Verify syslog threshold logic."""

    def test_level_all_sends_everything(self):
        tgmsg.SYSLOG_LEVEL = "all"
        tgmsg.SYSLOG_HOST = "127.0.0.1"
        self.assertTrue(tgmsg._should_syslog("silent"))
        self.assertTrue(tgmsg._should_syslog("normal"))
        self.assertTrue(tgmsg._should_syslog("warning"))
        self.assertTrue(tgmsg._should_syslog("critical"))

    def test_level_warning_skips_lower(self):
        tgmsg.SYSLOG_LEVEL = "warning"
        tgmsg.SYSLOG_HOST = "127.0.0.1"
        self.assertFalse(tgmsg._should_syslog("silent"))
        self.assertFalse(tgmsg._should_syslog("normal"))
        self.assertTrue(tgmsg._should_syslog("warning"))
        self.assertTrue(tgmsg._should_syslog("critical"))

    def test_level_critical_only_critical(self):
        tgmsg.SYSLOG_LEVEL = "critical"
        tgmsg.SYSLOG_HOST = "127.0.0.1"
        self.assertFalse(tgmsg._should_syslog("silent"))
        self.assertFalse(tgmsg._should_syslog("normal"))
        self.assertFalse(tgmsg._should_syslog("warning"))
        self.assertTrue(tgmsg._should_syslog("critical"))

    def test_no_host_always_false(self):
        tgmsg.SYSLOG_HOST = ""
        tgmsg.SYSLOG_LEVEL = "all"
        self.assertFalse(tgmsg._should_syslog("critical"))


class TestSendSyslog(unittest.TestCase):
    """Test syslog UDP send."""

    @patch("tgmsg.socket.socket")
    def test_syslog_sends_udp_packet(self, mock_socket_cls):
        tgmsg.SYSLOG_HOST = "127.0.0.1"
        tgmsg.SYSLOG_PORT = 1514
        tgmsg.SYSLOG_LEVEL = "all"

        mock_sock = MagicMock()
        mock_socket_cls.return_value = mock_sock

        result = tgmsg._send_syslog("test message", "critical")

        self.assertTrue(result)
        mock_sock.sendto.assert_called_once()
        sent_data = mock_sock.sendto.call_args[0][0].decode("utf-8")
        self.assertIn("tgmsg:", sent_data)
        self.assertIn("[CRITICAL]", sent_data)
        self.assertIn("test message", sent_data)
        # Verify RFC 3164 PRI: local0(16) * 8 + critical(2) = 130
        self.assertTrue(sent_data.startswith("<130>"))

    @patch("tgmsg.socket.socket")
    def test_syslog_handles_network_error(self, mock_socket_cls):
        tgmsg.SYSLOG_HOST = "127.0.0.1"
        tgmsg.SYSLOG_LEVEL = "all"

        mock_sock = MagicMock()
        mock_sock.sendto.side_effect = OSError("Network unreachable")
        mock_socket_cls.return_value = mock_sock

        result = tgmsg._send_syslog("fail test", "normal")
        self.assertFalse(result)

    def test_syslog_skipped_below_threshold(self):
        tgmsg.SYSLOG_HOST = "127.0.0.1"
        tgmsg.SYSLOG_LEVEL = "critical"
        result = tgmsg._send_syslog("low priority", "normal")
        self.assertFalse(result)


class TestSendTelegram(unittest.TestCase):
    """Test Telegram API calls."""

    @patch("tgmsg.urllib.request.urlopen")
    def test_telegram_success(self, mock_urlopen):
        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps({"ok": True}).encode()
        mock_resp.__enter__ = lambda s: mock_resp
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        tgmsg.TG_BOT_TOKEN = "111111:AAAA-test-token"
        tgmsg.TG_CHAT_ID = "999999"

        result = tgmsg._send_telegram("test message", "normal")
        self.assertTrue(result)
        mock_urlopen.assert_called_once()

    @patch("tgmsg.urllib.request.urlopen")
    def test_telegram_api_error(self, mock_urlopen):
        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps({"ok": False, "description": "Bad Request"}).encode()
        mock_resp.__enter__ = lambda s: mock_resp
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        result = tgmsg._send_telegram("test message", "normal")
        self.assertFalse(result)

    @patch("tgmsg.urllib.request.urlopen", side_effect=OSError("Connection refused"))
    def test_telegram_network_error(self, mock_urlopen):
        result = tgmsg._send_telegram("test message", "critical")
        self.assertFalse(result)

    def test_telegram_not_configured(self):
        tgmsg.TG_BOT_TOKEN = ""
        tgmsg.TG_CHAT_ID = ""
        result = tgmsg._send_telegram("test", "normal")
        self.assertFalse(result)
        # Restore
        tgmsg.TG_BOT_TOKEN = "111111:AAAA-test-token"
        tgmsg.TG_CHAT_ID = "999999"


class TestSendEmail(unittest.TestCase):
    """Test SMTP email."""

    @patch("tgmsg.smtplib.SMTP")
    def test_email_success(self, mock_smtp_cls):
        mock_server = MagicMock()
        mock_smtp_cls.return_value = mock_server

        tgmsg.SMTP_TO = "admin@localhost"
        result = tgmsg._send_email("test email", "", "warning")

        self.assertTrue(result)
        mock_server.sendmail.assert_called_once()
        mock_server.quit.assert_called_once()

    @patch("tgmsg.smtplib.SMTP", side_effect=OSError("Connection refused"))
    def test_email_connection_error(self, mock_smtp_cls):
        result = tgmsg._send_email("fail test", "", "normal")
        self.assertFalse(result)

    def test_email_not_configured(self):
        tgmsg.SMTP_TO = ""
        result = tgmsg._send_email("test", "", "normal")
        self.assertFalse(result)
        tgmsg.SMTP_TO = "admin@localhost"


class TestSend(unittest.TestCase):
    """Test the main send() function with fallback logic."""

    @patch("tgmsg._send_syslog", return_value=True)
    @patch("tgmsg._send_telegram", return_value=True)
    def test_telegram_success_skips_email(self, mock_tg, mock_syslog):
        result = tgmsg.send("test", "normal")
        self.assertTrue(result["delivered"])
        self.assertTrue(result["telegram"])
        self.assertFalse(result["email"])

    @patch("tgmsg._send_syslog", return_value=True)
    @patch("tgmsg._send_telegram", return_value=False)
    @patch("tgmsg._send_email", return_value=True)
    def test_telegram_fail_falls_back_to_email(self, mock_email, mock_tg, mock_syslog):
        result = tgmsg.send("test", "normal")
        self.assertTrue(result["delivered"])
        self.assertFalse(result["telegram"])
        self.assertTrue(result["email"])

    @patch("tgmsg._send_syslog", return_value=False)
    @patch("tgmsg._send_telegram", return_value=False)
    @patch("tgmsg._send_email", return_value=False)
    def test_all_channels_fail(self, mock_email, mock_tg, mock_syslog):
        result = tgmsg.send("test", "critical")
        self.assertFalse(result["delivered"])

    @patch("tgmsg._send_syslog", return_value=True)
    @patch("tgmsg._send_telegram", return_value=True)
    def test_syslog_fires_regardless(self, mock_tg, mock_syslog):
        tgmsg.send("test", "critical")
        mock_syslog.assert_called_once()

    @patch("tgmsg._send_syslog", return_value=True)
    @patch("tgmsg._send_telegram", return_value=True)
    def test_result_contains_all_keys(self, mock_tg, mock_syslog):
        result = tgmsg.send("test", "normal")
        self.assertIn("telegram", result)
        self.assertIn("email", result)
        self.assertIn("syslog", result)
        self.assertIn("delivered", result)


if __name__ == "__main__":
    unittest.main()
