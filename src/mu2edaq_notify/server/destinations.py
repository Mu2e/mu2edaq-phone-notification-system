"""Delivery backends: APNs, Slack, Discord.

APNs uses provider token (JWT/ES256) authentication over HTTP/2. Until
``apns.enabled`` is true and a key is configured the sender runs in
log-only mode: deliveries are recorded with status "logged" so the whole
pipeline can be exercised before Apple credentials exist.
"""
from __future__ import annotations

import logging
import threading
import time

import httpx

log = logging.getLogger(__name__)

SEVERITY_COLORS = {          # Discord embed / Slack attachment colors
    "debug": 0x8E8E93,
    "info": 0x2E86DE,
    "warning": 0xF39C12,
    "error": 0xE74C3C,
    "critical": 0x8E44AD,
}

APNS_HOST_PROD = "https://api.push.apple.com"
APNS_HOST_SANDBOX = "https://api.sandbox.push.apple.com"


class ApnsSender:
    def __init__(self, cfg):
        self.cfg = cfg
        self.enabled = bool(cfg.get("enabled"))
        self.bundle_id = cfg.get("bundle_id", "")
        self._jwt = None
        self._jwt_issued = 0.0
        self._lock = threading.Lock()
        self._client = None
        self._key = None
        if self.enabled:
            try:
                with open(cfg["key_file"], "rb") as fh:
                    self._key = fh.read()
                self._client = httpx.Client(
                    http2=True, timeout=10.0,
                    base_url=APNS_HOST_SANDBOX if cfg.get("sandbox")
                    else APNS_HOST_PROD)
            except OSError as exc:
                log.error("APNs key file unreadable (%s); falling back to "
                          "log-only mode", exc)
                self.enabled = False

    def _token(self):
        # Apple wants provider tokens refreshed between 20 and 60 minutes.
        import jwt
        with self._lock:
            if self._jwt is None or time.time() - self._jwt_issued > 1800:
                self._jwt = jwt.encode(
                    {"iss": self.cfg["team_id"], "iat": int(time.time())},
                    self._key, algorithm="ES256",
                    headers={"kid": self.cfg["key_id"]})
                self._jwt_issued = time.time()
            return self._jwt

    def send(self, apns_token, event):
        """Returns (status, detail): status is 'sent'|'logged'|'failed'."""
        payload = {
            "aps": {
                "alert": {"title": "[%s] %s" % (event["severity"].upper(),
                                                event["title"]),
                          "body": event["message"] or event["title"]},
                "sound": "default" if event["severity"] in
                         ("error", "critical") else None,
                "interruption-level":
                    "time-sensitive" if event["severity"] in
                    ("error", "critical") else "active",
            },
            "event": {k: event.get(k) for k in
                      ("id", "source", "host", "severity", "timestamp")},
        }
        if not self.enabled:
            log.info("APNs log-only: would push %r to %s...",
                     event["title"], apns_token[:8])
            return "logged", "APNs disabled; log-only"
        try:
            resp = self._client.post(
                "/3/device/" + apns_token, json=payload,
                headers={
                    "authorization": "bearer " + self._token(),
                    "apns-topic": self.bundle_id,
                    "apns-push-type": "alert",
                    "apns-priority": "10",
                })
            if resp.status_code == 200:
                return "sent", ""
            return "failed", "HTTP %s: %s" % (resp.status_code,
                                              resp.text[:200])
        except Exception as exc:
            return "failed", str(exc)

    def close(self):
        if self._client:
            self._client.close()


def _post_webhook(url, payload):
    try:
        resp = httpx.post(url, json=payload, timeout=10.0)
        if 200 <= resp.status_code < 300:
            return "sent", ""
        return "failed", "HTTP %s: %s" % (resp.status_code, resp.text[:200])
    except Exception as exc:
        return "failed", str(exc)


def send_slack(webhook_url, event):
    color = "#%06x" % SEVERITY_COLORS.get(event["severity"], 0x2E86DE)
    payload = {
        "text": "[%s] %s" % (event["severity"].upper(), event["title"]),
        "attachments": [{
            "color": color,
            "fields": [
                {"title": "Source", "value": event["source"], "short": True},
                {"title": "Host", "value": event["host"], "short": True},
                {"title": "Time", "value": event["timestamp"], "short": True},
            ],
            "text": event["message"],
        }],
    }
    return _post_webhook(webhook_url, payload)


def send_discord(webhook_url, event):
    payload = {
        "embeds": [{
            "title": "[%s] %s" % (event["severity"].upper(), event["title"]),
            "description": event["message"][:2000],
            "color": SEVERITY_COLORS.get(event["severity"], 0x2E86DE),
            "fields": [
                {"name": "Source", "value": event["source"] or "-",
                 "inline": True},
                {"name": "Host", "value": event["host"] or "-",
                 "inline": True},
            ],
            "timestamp": event["timestamp"],
        }],
    }
    return _post_webhook(webhook_url, payload)
