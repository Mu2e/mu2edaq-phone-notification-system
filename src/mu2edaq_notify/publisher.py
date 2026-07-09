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

Discovery resolves two addresses: a primary (the server's own local
address, so on-network publishers connect directly) and a fallback
(carried in the ANNOUNCE metadata, typically the public reverse-proxy
URL). ``publish()`` tries the primary first and only tries the fallback
when the primary is unreachable at the network level (DNS/connection/
timeout failure) -- an explicit rejection from the server (bad token,
bad payload) is not retried against the fallback.
"""
from __future__ import annotations

import json
import logging
import os
import socket
import ssl
import urllib.error
import urllib.request

from .events import normalize_event

log = logging.getLogger(__name__)

ENV_URL = "MU2EDAQ_NOTIFY_URL"
ENV_TOKEN = "MU2EDAQ_NOTIFY_TOKEN"
ENV_FALLBACK_URL = "MU2EDAQ_NOTIFY_FALLBACK_URL"
DISCOVERY_APP = "notify"


class _Unreachable(Exception):
    """Raised internally when a POST fails at the network level (as
    opposed to being reached and rejected by the server)."""


def https_context():
    """Return an SSL context with a usable CA bundle.

    Python.org framework builds on macOS can have an empty OpenSSL CA
    path until the separate certificate install step has run. Prefer
    certifi when available so the publisher CLI validates public HTTPS
    endpoints consistently.
    """
    try:
        import certifi
    except ImportError:
        return ssl.create_default_context()
    return ssl.create_default_context(cafile=certifi.where())


def _discover_server(timeout=2.0):
    """Locate the notification server via mu2edaq-discovery, if available.

    Returns ``(primary_url, fallback_url)``; either may be None. The
    primary is the server's own advertised local address; the fallback
    is read from ``meta.fallback_url`` on the same ANNOUNCE, when
    present (typically the public reverse-proxy URL).
    """
    try:
        from mu2edaq_discovery import discover
    except ImportError:
        return None, None
    try:
        services = discover(filter={"app": DISCOVERY_APP}, timeout=timeout)
    except Exception as exc:  # discovery is best-effort
        log.debug("discovery failed: %s", exc)
        return None, None
    for svc in services or []:
        host = svc.get("host") or svc.get("address")
        port = svc.get("port")
        if host and port:
            scheme = svc.get("scheme", "http")
            primary = "%s://%s:%s" % (scheme, host, port)
            fallback = (svc.get("meta") or {}).get("fallback_url") or None
            return primary, fallback
    return None, None


class NotifyPublisher:
    """Publishes events to the notification server over HTTP."""

    def __init__(self, server_url=None, token=None, source=None,
                 host=None, timeout=5.0, discover=True, fallback_url=None):
        self.server_url = server_url or os.environ.get(ENV_URL)
        self.fallback_url = fallback_url or os.environ.get(ENV_FALLBACK_URL)
        if discover and (not self.server_url or not self.fallback_url):
            d_primary, d_fallback = _discover_server()
            self.server_url = self.server_url or d_primary
            self.fallback_url = self.fallback_url or d_fallback
        self.token = token or os.environ.get(ENV_TOKEN)
        self.source = source or os.path.basename(os.environ.get("_", "")) or "python"
        self.host = host or socket.gethostname()
        self.timeout = timeout

    def _post(self, url, body):
        """POST one event body to ``url``. Returns True/False when the
        server was reached; raises _Unreachable on a network-level
        failure (so the caller can try a fallback address)."""
        full_url = url.rstrip("/") + "/api/events"
        req = urllib.request.Request(
            full_url, data=body, method="POST",
            headers={"Content-Type": "application/json"})
        if self.token:
            req.add_header("Authorization", "Bearer " + self.token)
        try:
            with urllib.request.urlopen(
                    req, timeout=self.timeout,
                    context=https_context()) as resp:
                return 200 <= resp.status < 300
        except urllib.error.HTTPError as exc:
            log.warning("notification server at %s rejected event (%s): %s",
                        url, exc.code, exc.reason)
            return False
        except Exception as exc:
            log.warning("could not reach notification server at %s: %s",
                        url, exc)
            raise _Unreachable(exc)

    def publish(self, severity, title, message="", source=None, meta=None):
        """Send one event. Returns True on success, False otherwise.

        Tries ``server_url`` first, then ``fallback_url`` -- but only
        when the primary was unreachable at the network level; a
        rejection from a reachable server (bad token, bad payload) is
        not retried against the fallback. Never raises on delivery
        failure -- publishing a notification must not be able to take
        down a DAQ application.
        """
        urls = []
        for url in (self.server_url, self.fallback_url):
            if url and url not in urls:
                urls.append(url)
        if not urls:
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
        for i, url in enumerate(urls):
            try:
                return self._post(url, body)
            except _Unreachable:
                if i + 1 < len(urls):
                    log.info("primary notify server %s unreachable; "
                             "trying fallback %s", url, urls[i + 1])
        log.warning("no configured notification server was reachable; "
                    "event dropped: %s", title)
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
                  ("server_url", "fallback_url", "token", "host", "timeout",
                   "discover")
                  if k in kwargs}
    return NotifyPublisher(**pub_kwargs).publish(
        severity, title, message, **kwargs)
