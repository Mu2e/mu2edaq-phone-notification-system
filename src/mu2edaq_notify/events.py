"""Event schema shared by the publisher library and the server.

An event is a plain dict:

    {
      "source":    "dtc-monitor",          # publishing application
      "host":      "mu2edaq09",            # node it ran on
      "severity":  "error",                # debug|info|warning|error|critical
      "category":  "Trigger",              # operator-defined subsystem tag
      "title":     "DTC link down",        # short, shows in the push banner
      "message":   "ROC link 3 lost lock", # detail body
      "timestamp": "2026-07-07T12:00:00+00:00",  # ISO-8601 UTC
      "meta":      {"run": "107001"}       # optional string map
    }

``category`` is a freeform string here: the canonical list of expected
category names is operator-configurable (``categories:`` in
notify-server.yaml), so this module -- shared by the publisher, which
has no view of the server's config -- does not validate against it. The
server surfaces the configured list at ``GET /api/categories`` and uses
it to populate the web UI's pickers; unrecognized categories are still
accepted and stored so a typo or a not-yet-added subsystem never causes
an event to be dropped.
"""
from __future__ import annotations

import socket
from datetime import datetime, timezone

SEVERITIES = ["debug", "info", "warning", "error", "critical"]

_MAX_TITLE = 200
_MAX_MESSAGE = 4000
_MAX_CATEGORY = 100


def severity_index(severity):
    """Rank of a severity name (unknown names rank as ``info``)."""
    try:
        return SEVERITIES.index(str(severity).lower())
    except ValueError:
        return SEVERITIES.index("info")


def utc_now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def normalize_event(payload, default_source="unknown", default_severity="info"):
    """Coerce an arbitrary payload dict into a well-formed event dict.

    Raises ValueError if there is nothing usable in the payload.
    """
    if not isinstance(payload, dict):
        raise ValueError("event payload must be a JSON object")

    title = str(payload.get("title") or "").strip()
    message = str(payload.get("message") or "").strip()
    if not title and not message:
        raise ValueError("event needs a title or a message")
    if not title:
        title = message.splitlines()[0][:_MAX_TITLE]

    severity = str(payload.get("severity") or default_severity).lower()
    if severity not in SEVERITIES:
        severity = default_severity

    meta = payload.get("meta") or {}
    if not isinstance(meta, dict):
        meta = {"value": str(meta)}
    meta = {str(k): str(v) for k, v in meta.items()}

    return {
        "source": str(payload.get("source") or default_source)[:100],
        "host": str(payload.get("host") or socket.gethostname())[:100],
        "severity": severity,
        "category": str(payload.get("category") or "").strip()[:_MAX_CATEGORY],
        "title": title[:_MAX_TITLE],
        "message": message[:_MAX_MESSAGE],
        "timestamp": str(payload.get("timestamp") or utc_now_iso()),
        "meta": meta,
    }
