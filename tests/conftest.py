import pytest

from mu2edaq_notify.server.app import create_app
from mu2edaq_notify.server.config import load_config
from mu2edaq_notify.server.storage import Storage


@pytest.fixture
def cfg(tmp_path):
    config = load_config(config_file=None, environ={}, overrides=[
        (("database", "url"), "sqlite:///%s" % (tmp_path / "test.db")),
        (("auth", "api_tokens"), ["test-api-token"]),
    ])
    return config


@pytest.fixture
def storage(cfg):
    return Storage(cfg["database"]["url"])


@pytest.fixture
def app(cfg, storage):
    application = create_app(cfg, storage)
    application.config["TESTING"] = True
    return application


@pytest.fixture
def client(app):
    return app.test_client()


@pytest.fixture
def auth_header():
    return {"Authorization": "Bearer test-api-token"}


def make_event(**overrides):
    event = {
        "source": "dtc-monitor",
        "host": "mu2edaq09",
        "severity": "error",
        "category": "Trigger",
        "title": "DTC link down",
        "message": "ROC link 3 lost lock",
        "meta": {"run": "107001"},
    }
    event.update(overrides)
    return event
