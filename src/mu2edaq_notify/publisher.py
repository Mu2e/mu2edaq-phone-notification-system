"""Publisher library: send events to the Mu2e DAQ notification server.

Runtime dependencies: Python standard library only, so any DAQ
application or script can publish without extra packages. The server
address can be given explicitly, taken from the environment, or found
via mu2edaq-discovery when that package is importable.

    from mu2edaq_notify import NotifyPublisher

    pub = NotifyPublisher(token="my-api-token")   # server found via discovery
    pub.error("DTC link down", "ROC link 3 lost lock", source="dtc-monitor")

Configuration precedence: constructor arguments > environment
(``MU2EDAQ_NOTIFY_URL``, ``MU2EDAQ_NOTIFY_TOKEN``) > discovery.
"""
from __future__ import annotations

import json
import logging
import os
import socket
import urllib.error
import urllib.request

from .events import normalize_event

log = logging.getLogger(__name__)

ENV_URL = "MU2EDAQ_NOTIFY_URL"
ENV_TOKEN = "MU2EDAQ_NOTIFY_TOKEN"
DISCOVERY_APP = "notify"


def _discover_server(timeout=2.0):
    """Locate the notification server via mu2edaq-discovery, if available."""
    try:
        from mu2edaq_discovery import discover
    except ImportError:
        return None
    try:
        services = discover(filter={"app": DISCOVERY_APP}, timeout=timeout)
    except Exception as exc:  # discovery is best-effort
        log.debug("discovery failed: %s", exc)
        return None
    for svc in services or []:
        host = svc.get("host") or svc.get("address")
        port = svc.get("port")
        if host and port:
            scheme = svc.get("scheme", "http")
            return "%s://%s:%s" % (scheme, host, port)
    return None


class NotifyPublisher:
    """Publishes events to the notification server over HTTP."""

    def __init__(self, server_url=None, token=None, source=None,
                 host=None, timeout=5.0, discover=True):
        self.server_url = (server_url or os.environ.get(ENV_URL) or
                           (_discover_server() if discover else None))
        self.token = token or os.environ.get(ENV_TOKEN)
        self.source = source or os.path.basename(os.environ.get("_", "")) or "python"
        self.host = host or socket.gethostname()
        self.timeout = timeout

    def publish(self, severity, title, message="", source=None, meta=None):
        """Send one event. Returns True on success, False otherwise.

        Never raises on delivery failure -- publishing a notification
        must not be able to take down a DAQ application.
        """
        if not self.server_url:
            log.warning("no notification server configured or discovered; "
                        "event dropped: %s", title)
            return False
        event = normalize_event({
            "severity": severity,
            "title": title,
            "message": message,
            "source": source or self.source,
            "host": self.host,
            "meta": meta or {},
        })
        body = json.dumps(event).encode()
        url = self.server_url.rstrip("/") + "/api/events"
        req = urllib.request.Request(
            url, data=body, method="POST",
            headers={"Content-Type": "application/json"})
        if self.token:
            req.add_header("Authorization", "Bearer " + self.token)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return 200 <= resp.status < 300
        except urllib.error.HTTPError as exc:
            log.warning("notification server rejected event (%s): %s",
                        exc.code, exc.reason)
        except Exception as exc:
            log.warning("could not reach notification server at %s: %s",
                        url, exc)
        return False

    # Convenience wrappers -------------------------------------------------
    def debug(self, title, message="", **kw):
        return self.publish("debug", title, message, **kw)

    def info(self, title, message="", **kw):
        return self.publish("info", title, message, **kw)

    def warning(self, title, message="", **kw):
        return self.publish("warning", title, message, **kw)

    def error(self, title, message="", **kw):
        return self.publish("error", title, message, **kw)

    def critical(self, title, message="", **kw):
        return self.publish("critical", title, message, **kw)


def publish_event(severity, title, message="", **kwargs):
    """One-shot module-level convenience: build a publisher and send."""
    pub_kwargs = {k: kwargs.pop(k) for k in
                  ("server_url", "token", "host", "timeout", "discover")
                  if k in kwargs}
    return NotifyPublisher(**pub_kwargs).publish(
        severity, title, message, **kwargs)
