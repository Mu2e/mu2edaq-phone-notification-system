"""End-to-end publisher test: NotifyPublisher -> real HTTP -> server."""
import threading

import pytest
from werkzeug.serving import make_server

from mu2edaq_notify.publisher import (NotifyPublisher, https_context,
                                      publish_event)


@pytest.fixture
def live_server(app):
    server = make_server("127.0.0.1", 0, app)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield "http://127.0.0.1:%d" % server.server_port
    server.shutdown()


def test_publish_roundtrip(live_server, storage):
    pub = NotifyPublisher(server_url=live_server, token="test-api-token",
                          source="pytest", discover=False)
    assert pub.error("Publisher test", "hello from pytest",
                     meta={"k": "v"}) is True
    events = storage.list_events()
    assert events[0]["title"] == "Publisher test"
    assert events[0]["source"] == "pytest"
    assert events[0]["meta"] == {"k": "v"}


def test_publish_with_bad_token_fails(live_server):
    pub = NotifyPublisher(server_url=live_server, token="wrong",
                          discover=False)
    assert pub.warning("nope") is False


def test_publish_without_server_returns_false():
    pub = NotifyPublisher(server_url=None, discover=False)
    pub.server_url = None
    assert pub.info("dropped") is False


def test_module_level_convenience(live_server, storage):
    assert publish_event("warning", "One-shot", server_url=live_server,
                         token="test-api-token", discover=False,
                         source="oneshot") is True
    assert storage.list_events()[0]["source"] == "oneshot"


def test_env_configuration(live_server, storage, monkeypatch):
    monkeypatch.setenv("MU2EDAQ_NOTIFY_URL", live_server)
    monkeypatch.setenv("MU2EDAQ_NOTIFY_TOKEN", "test-api-token")
    pub = NotifyPublisher(discover=False)
    assert pub.critical("From env") is True


def test_https_context_uses_certifi_when_available():
    ctx = https_context()
    assert ctx.verify_mode.name == "CERT_REQUIRED"


# Category -------------------------------------------------------------------

def test_publish_category_per_call(live_server, storage):
    pub = NotifyPublisher(server_url=live_server, token="test-api-token",
                          discover=False)
    assert pub.error("Categorized", category="Tracker") is True
    assert storage.list_events()[0]["category"] == "Tracker"


def test_publish_category_defaults_from_constructor(live_server, storage):
    pub = NotifyPublisher(server_url=live_server, token="test-api-token",
                          category="Trigger", discover=False)
    assert pub.warning("Uses constructor default") is True
    assert storage.list_events()[0]["category"] == "Trigger"


def test_publish_category_per_call_overrides_constructor_default(
        live_server, storage):
    pub = NotifyPublisher(server_url=live_server, token="test-api-token",
                          category="Trigger", discover=False)
    assert pub.warning("Override", category="Tracker") is True
    assert storage.list_events()[0]["category"] == "Tracker"


def test_publish_without_category_is_uncategorized(live_server, storage):
    pub = NotifyPublisher(server_url=live_server, token="test-api-token",
                          discover=False)
    assert pub.warning("No category") is True
    assert storage.list_events()[0]["category"] == ""


def test_category_env_var(live_server, storage, monkeypatch):
    monkeypatch.setenv("MU2EDAQ_NOTIFY_CATEGORY", "Calorimeter")
    pub = NotifyPublisher(server_url=live_server, token="test-api-token",
                          discover=False)
    assert pub.warning("From env category") is True
    assert storage.list_events()[0]["category"] == "Calorimeter"


# Fallback (local-primary, public-secondary) behavior ------------------------

UNREACHABLE = "http://127.0.0.1:1"   # connection refused, fails fast


def test_publish_falls_back_when_primary_unreachable(live_server, storage):
    pub = NotifyPublisher(server_url=UNREACHABLE, fallback_url=live_server,
                          token="test-api-token", discover=False,
                          timeout=2.0)
    assert pub.warning("Fallback test") is True
    events = storage.list_events()
    assert events[0]["title"] == "Fallback test"


def test_publish_returns_false_when_both_unreachable():
    pub = NotifyPublisher(server_url=UNREACHABLE,
                          fallback_url="http://127.0.0.1:2",
                          discover=False, timeout=2.0)
    assert pub.warning("nowhere to go") is False


def test_publish_does_not_retry_fallback_on_http_rejection(
        live_server, storage, monkeypatch):
    # A reachable server that explicitly rejects the request (bad token)
    # must not be retried against the fallback -- retrying won't fix a
    # bad token/payload and would risk duplicate deliveries.
    calls = []
    original_post = NotifyPublisher._post

    def counting_post(self, url, body):
        calls.append(url)
        return original_post(self, url, body)

    monkeypatch.setattr(NotifyPublisher, "_post", counting_post)
    pub = NotifyPublisher(server_url=live_server, fallback_url=UNREACHABLE,
                          token="wrong-token", discover=False)
    assert pub.warning("no retry") is False
    assert calls == [live_server]
    assert storage.list_events() == []


def test_discover_server_fills_in_missing_primary_and_fallback(monkeypatch):
    import mu2edaq_notify.publisher as publisher_mod

    monkeypatch.setattr(
        publisher_mod, "_discover_server",
        lambda timeout=2.0: ("http://mu2edaq09:8095",
                             "https://notify.andrewnorman.org"))
    pub = NotifyPublisher(discover=True)
    assert pub.server_url == "http://mu2edaq09:8095"
    assert pub.fallback_url == "https://notify.andrewnorman.org"


def test_explicit_server_url_skips_discovery_for_primary_only(monkeypatch):
    # An explicit server_url should not be overridden by discovery, but
    # a missing fallback should still be filled in from it.
    import mu2edaq_notify.publisher as publisher_mod

    monkeypatch.setattr(
        publisher_mod, "_discover_server",
        lambda timeout=2.0: ("http://discovered-primary:8095",
                             "https://notify.andrewnorman.org"))
    pub = NotifyPublisher(server_url="http://pinned:8095", discover=True)
    assert pub.server_url == "http://pinned:8095"
    assert pub.fallback_url == "https://notify.andrewnorman.org"
