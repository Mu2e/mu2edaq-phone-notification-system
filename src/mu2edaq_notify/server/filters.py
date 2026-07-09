"""Filter engine: decide which destinations receive an event."""
from __future__ import annotations

import fnmatch
import logging
import re

from ..events import severity_index

log = logging.getLogger(__name__)


def rule_matches(rule, event):
    """True if a filter rule dict matches an event dict."""
    if not rule.get("enabled", True):
        return False
    if severity_index(event["severity"]) < severity_index(
            rule.get("min_severity", "debug")):
        return False
    if not fnmatch.fnmatch(event.get("source", ""),
                           rule.get("source_pattern") or "*"):
        return False
    if not fnmatch.fnmatch(event.get("host", ""),
                           rule.get("host_pattern") or "*"):
        return False
    if not fnmatch.fnmatch(event.get("category", ""),
                           rule.get("category_pattern") or "*"):
        return False
    regex = rule.get("message_regex") or ""
    if regex:
        try:
            if not re.search(regex, event.get("message", "") or
                             event.get("title", "")):
                return False
        except re.error as exc:
            log.warning("bad regex in filter %r: %s", rule.get("name"), exc)
            return False
    return True


def match_destinations(rules, event):
    """Names of every destination selected by any matching rule."""
    names = []
    for rule in rules:
        if rule_matches(rule, event):
            for dest in rule.get("destinations", []):
                if dest not in names:
                    names.append(dest)
    return names
