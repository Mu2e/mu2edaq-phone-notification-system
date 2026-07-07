"""Mu2e DAQ phone push notification system.

Two public faces:

* :mod:`mu2edaq_notify.publisher` -- stdlib-only client library DAQ
  applications use to publish events to the notification server.
* :mod:`mu2edaq_notify.server` -- the notification server (Flask web
  application, filter engine, APNs / Slack / Discord dispatch).
"""

from .events import SEVERITIES, normalize_event, severity_index
from .publisher import NotifyPublisher, publish_event

__version__ = "0.1.0"

__all__ = [
    "SEVERITIES",
    "normalize_event",
    "severity_index",
    "NotifyPublisher",
    "publish_event",
    "__version__",
]
