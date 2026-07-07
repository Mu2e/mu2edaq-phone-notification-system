"""ZeroMQ compatibility listener tests (skipped without pyzmq)."""
import json
import time

import pytest

zmq = pytest.importorskip("zmq")

from mu2edaq_notify.server.zmq_listener import ZmqListener  # noqa: E402


@pytest.fixture
def listener_setup():
    received = []
    cfg = {"connect": [], "bind": "tcp://127.0.0.1:0",
           "default_severity": "warning", "default_source": "zmq"}
    # Bind an explicit ephemeral-style port via a real socket first.
    ctx = zmq.Context.instance()
    probe = ctx.socket(zmq.PULL)
    port = probe.bind_to_random_port("tcp://127.0.0.1")
    probe.close(0)
    cfg["bind"] = "tcp://127.0.0.1:%d" % port
    listener = ZmqListener(cfg, received.append)
    listener.start()
    time.sleep(0.2)
    yield cfg, received
    listener.stop()


def push(endpoint, payload):
    ctx = zmq.Context.instance()
    sock = ctx.socket(zmq.PUSH)
    sock.connect(endpoint)
    time.sleep(0.1)
    sock.send(payload)
    sock.close(0)


def wait_for(received, n, timeout=3.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if len(received) >= n:
            return True
        time.sleep(0.05)
    return False


def test_json_event_over_zmq(listener_setup):
    cfg, received = listener_setup
    push(cfg["bind"], json.dumps({
        "severity": "error", "title": "ZMQ event",
        "message": "via push socket", "source": "zmqtest"}).encode())
    assert wait_for(received, 1)
    assert received[0]["title"] == "ZMQ event"
    assert received[0]["severity"] == "error"
    assert received[0]["source"] == "zmqtest"


def test_plain_text_becomes_default_severity_event(listener_setup):
    cfg, received = listener_setup
    push(cfg["bind"], b"RUN STATE stopped")
    assert wait_for(received, 1)
    assert received[0]["message"] == "RUN STATE stopped"
    assert received[0]["severity"] == "warning"
    assert received[0]["source"] == "zmq"
