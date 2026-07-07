"""ZeroMQ compatibility listener.

Accepts events over the existing Mu2e DAQ ZeroMQ publishing scheme
(the downtime-logger style) so applications already publishing on zmq
need no changes:

* JSON object payloads are treated as full event dicts.
* Plain-text payloads become events with the configured default
  severity/source (the text is the message).

Two socket modes, both optional: SUB sockets *connecting* to publisher
endpoints listed in ``zmq.connect``, and a PULL socket *bound* at
``zmq.bind`` that fire-and-forget publishers can PUSH to.
"""
from __future__ import annotations

import json
import logging
import threading

from ..events import normalize_event

log = logging.getLogger(__name__)


class ZmqListener:
    def __init__(self, cfg, ingest_callback):
        """``ingest_callback(event_dict)`` is called for each message."""
        self.cfg = cfg
        self.ingest = ingest_callback
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True,
                                        name="notify-zmq")

    def start(self):
        self._thread.start()

    def stop(self, timeout=3.0):
        self._stop.set()
        self._thread.join(timeout)

    def _parse(self, raw):
        text = raw.decode(errors="replace").strip()
        try:
            payload = json.loads(text)
            if not isinstance(payload, dict):
                raise ValueError
        except ValueError:
            payload = {"message": text,
                       "severity": self.cfg.get("default_severity",
                                                "warning")}
        return normalize_event(
            payload,
            default_source=self.cfg.get("default_source", "zmq"),
            default_severity=self.cfg.get("default_severity", "warning"))

    def _run(self):
        try:
            import zmq
        except ImportError:
            log.warning("pyzmq not installed; zmq listener disabled")
            return
        ctx = zmq.Context.instance()
        poller = zmq.Poller()
        sockets = []
        for endpoint in self.cfg.get("connect") or []:
            sock = ctx.socket(zmq.SUB)
            sock.setsockopt(zmq.SUBSCRIBE, b"")
            sock.connect(endpoint)
            poller.register(sock, zmq.POLLIN)
            sockets.append(sock)
            log.info("zmq SUB connected to %s", endpoint)
        bind = self.cfg.get("bind")
        if bind:
            sock = ctx.socket(zmq.PULL)
            sock.bind(bind)
            poller.register(sock, zmq.POLLIN)
            sockets.append(sock)
            log.info("zmq PULL bound at %s", bind)
        if not sockets:
            log.info("zmq listener enabled but no endpoints configured")
            return
        while not self._stop.is_set():
            for sock, _ in poller.poll(timeout=500):
                try:
                    event = self._parse(sock.recv(flags=zmq.NOBLOCK))
                    self.ingest(event)
                except Exception as exc:
                    log.warning("bad zmq message dropped: %s", exc)
        for sock in sockets:
            sock.close(0)
