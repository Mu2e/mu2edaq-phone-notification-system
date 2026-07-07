"""End-to-end publisher test: NotifyPublisher -> real HTTP -> server."""
import threading

import pytest
from werkzeug.serving import make_server

from mu2edaq_notify.publisher import NotifyPublisher, publish_event


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
