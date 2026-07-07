import pytest

from mu2edaq_notify.events import (SEVERITIES, normalize_event,
                                   severity_index)


def test_severity_ordering():
    assert severity_index("debug") < severity_index("info")
    assert severity_index("warning") < severity_index("error")
    assert severity_index("error") < severity_index("critical")


def test_unknown_severity_ranks_as_info():
    assert severity_index("bogus") == severity_index("info")


def test_normalize_full_event():
    event = normalize_event({
        "source": "dtc", "host": "node1", "severity": "ERROR",
        "title": "Link down", "message": "detail",
        "meta": {"run": 107001},
    })
    assert event["severity"] == "error"
    assert event["source"] == "dtc"
    assert event["meta"] == {"run": "107001"}
    assert event["timestamp"]


def test_normalize_defaults():
    event = normalize_event({"message": "just a message\nsecond line"})
    assert event["title"] == "just a message"
    assert event["severity"] == "info"
    assert event["host"]  # filled with local hostname


def test_normalize_bad_severity_uses_default():
    event = normalize_event({"title": "x", "severity": "shrug"},
                            default_severity="warning")
    assert event["severity"] == "warning"


def test_normalize_rejects_empty():
    with pytest.raises(ValueError):
        normalize_event({})
    with pytest.raises(ValueError):
        normalize_event("not a dict")


def test_normalize_truncates():
    event = normalize_event({"title": "t" * 500, "message": "m" * 10000})
    assert len(event["title"]) <= 200
    assert len(event["message"]) <= 4000


def test_severity_list_is_ordered():
    assert SEVERITIES == ["debug", "info", "warning", "error", "critical"]
