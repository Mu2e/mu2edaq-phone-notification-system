"""Dispatcher: match incoming events against filter rules and deliver
them to destinations (APNs devices, Slack, Discord) from a background
daemon thread.
"""
from __future__ import annotations

import logging
import queue
import threading
import time

from .destinations import ApnsSender, send_discord, send_slack
from .filters import match_destinations

log = logging.getLogger(__name__)


class Dispatcher:
    def __init__(self, storage, cfg, sse_hub=None):
        self.storage = storage
        self.cfg = cfg
        self.sse_hub = sse_hub
        self.apns = ApnsSender(cfg["apns"])
        self._queue = queue.Queue()
        self._recent = {}   # (rule-key) -> monotonic time, for rate limiting
        self._recent_lock = threading.Lock()
        self._thread = threading.Thread(target=self._run, daemon=True,
                                        name="notify-dispatcher")
        self._stop = threading.Event()

    def start(self):
        self._thread.start()

    def stop(self, timeout=5.0):
        self._stop.set()
        self._queue.put(None)
        self._thread.join(timeout)
        self.apns.close()

    def submit(self, event):
        """Queue a stored event dict (must have an ``id``) for delivery."""
        self._queue.put(event)
        if self.sse_hub:
            self.sse_hub.publish("event", event)

    # Internals --------------------------------------------------------------
    def _rate_limited(self, event):
        window = float(self.cfg["dispatch"].get("rate_limit_seconds", 0))
        if window <= 0:
            return False
        key = (event["source"], event["severity"], event["title"])
        now = time.monotonic()
        with self._recent_lock:
            last = self._recent.get(key)
            if last is not None and now - last < window:
                return True
            self._recent[key] = now
            if len(self._recent) > 5000:  # keep the suppression table bounded
                cutoff = now - window
                self._recent = {k: t for k, t in self._recent.items()
                                if t >= cutoff}
        return False

    def _run(self):
        while not self._stop.is_set():
            event = self._queue.get()
            if event is None:
                continue
            try:
                self._dispatch(event)
            except Exception:
                log.exception("dispatch failed for event %s",
                              event.get("id"))

    def _dispatch(self, event):
        rules = self.storage.list_filters()
        names = match_destinations(rules, event)
        if not names:
            return
        if self._rate_limited(event):
            for name in names:
                self.storage.add_delivery(event["id"], name, "",
                                          "suppressed", "rate limited")
            return
        dest_by_name = {d["name"]: d for d in
                        self.storage.list_destinations()}
        for name in names:
            dest = dest_by_name.get(name)
            if not dest or not dest["enabled"]:
                continue
            if dest["type"] == "apns":
                self._deliver_apns(event, dest)
            elif dest["type"] == "slack":
                status, detail = send_slack(dest["webhook_url"], event)
                self.storage.add_delivery(event["id"], name, "slack",
                                          status, detail)
            elif dest["type"] == "discord":
                status, detail = send_discord(dest["webhook_url"], event)
                self.storage.add_delivery(event["id"], name, "discord",
                                          status, detail)

    def _deliver_apns(self, event, dest):
        targets = self.storage.apns_targets(event["severity"])
        if not targets:
            self.storage.add_delivery(event["id"], dest["name"], "",
                                      "logged", "no registered devices")
            return
        for device in targets:
            status, detail = self.apns.send(device["apns_token"], event)
            self.storage.add_delivery(event["id"], dest["name"],
                                      device["name"], status, detail)
