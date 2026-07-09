import json

from mu2edaq_notify.server import auth
from mu2edaq_notify.server.app import create_app
from mu2edaq_notify.server.config import load_config
from mu2edaq_notify.server.storage import Storage
from conftest import make_event


def test_health(client):
    data = client.get("/api/health").get_json()
    assert data["status"] == "ok"
    assert "version" in data


def test_categories_endpoint_empty_by_default(client):
    assert client.get("/api/categories").get_json() == {"categories": []}


def test_categories_endpoint_reflects_config(tmp_path):
    cfg = load_config(environ={}, overrides=[
        (("database", "url"), "sqlite:///%s" % (tmp_path / "cat.db")),
        (("categories",), ["DAQ", "Trigger", "Tracker"]),
    ])
    storage = Storage(cfg["database"]["url"])
    app = create_app(cfg, storage)
    app.config["TESTING"] = True
    resp = app.test_client().get("/api/categories")
    assert resp.get_json() == {"categories": ["DAQ", "Trigger", "Tracker"]}


def test_post_event_requires_token(client):
    resp = client.post("/api/events", json=make_event())
    assert resp.status_code == 401


def test_post_event_and_fetch(client, auth_header):
    resp = client.post("/api/events", json=make_event(),
                       headers=auth_header)
    assert resp.status_code == 201
    event_id = resp.get_json()["id"]

    listing = client.get("/api/events", headers=auth_header).get_json()
    assert listing["events"][0]["id"] == event_id

    detail = client.get("/api/events/%d" % event_id,
                        headers=auth_header).get_json()
    assert detail["title"] == "DTC link down"
    assert "deliveries" in detail


def test_post_bad_event_rejected(client, auth_header):
    resp = client.post("/api/events", json={}, headers=auth_header)
    assert resp.status_code == 400


def test_post_event_with_category_and_filter_by_it(client, auth_header):
    client.post("/api/events", json=make_event(category="Tracker"),
               headers=auth_header)
    client.post("/api/events", json=make_event(category="Trigger"),
               headers=auth_header)

    tracker_only = client.get("/api/events?category=Tracker",
                              headers=auth_header).get_json()["events"]
    assert len(tracker_only) == 1
    assert tracker_only[0]["category"] == "Tracker"

    all_events = client.get("/api/events",
                            headers=auth_header).get_json()["events"]
    assert len(all_events) == 2


def test_post_event_category_defaults_to_empty(client, auth_header):
    resp = client.post("/api/events", json={"title": "no category"},
                       headers=auth_header)
    assert resp.get_json()["category"] == ""


def test_device_enrollment_flow(client, app, auth_header):
    cfg = app.config["NOTIFY_CFG"]
    enrollment = auth.make_enrollment_token(cfg)

    # Auto-configuration payload the phone would fetch.
    autocfg = client.get("/api/autoconfig/" + enrollment).get_json()
    assert autocfg["type"] == "mu2edaq-notify-config"
    assert autocfg["enrollment_token"] == enrollment

    # Register with the enrollment token.
    resp = client.post("/api/devices/register", json={
        "enrollment_token": enrollment,
        "name": "Test iPhone", "apns_token": "abc123"})
    assert resp.status_code == 201
    device_token = resp.get_json()["device_token"]

    # The device token authenticates device endpoints.
    resp = client.post("/api/devices/token",
                       json={"apns_token": "rotated456"},
                       headers={"Authorization": "Bearer " + device_token})
    assert resp.status_code == 200

    resp = client.post("/api/devices/settings",
                       json={"min_severity": "error"},
                       headers={"Authorization": "Bearer " + device_token})
    assert resp.get_json()["device"]["min_severity"] == "error"

    # Device tokens can read events too.
    resp = client.get("/api/events",
                      headers={"Authorization": "Bearer " + device_token})
    assert resp.status_code == 200


def test_registration_rejects_bad_enrollment_token(client):
    resp = client.post("/api/devices/register", json={
        "enrollment_token": "garbage", "name": "X"})
    assert resp.status_code == 401


def test_enrollment_qr_png(client, app):
    cfg = app.config["NOTIFY_CFG"]
    token = auth.make_enrollment_token(cfg)
    resp = client.get("/devices/qr.png?token=" + token)
    assert resp.status_code == 200
    assert resp.mimetype == "image/png"
    assert resp.data[:8] == b"\x89PNG\r\n\x1a\n"
    assert client.get("/devices/qr.png?token=bad").status_code == 404


def test_web_pages_render(client, auth_header, app):
    # Put one event in so the dashboard has content.
    client.post("/api/events", json=make_event(), headers=auth_header)
    for path in ("/", "/filters", "/destinations", "/devices",
                 "/about", "/api-docs", "/sitemap", "/events/1"):
        resp = client.get(path)
        assert resp.status_code == 200, path


def test_dashboard_renders_category_chips_when_configured(tmp_path):
    cfg = load_config(environ={}, overrides=[
        (("database", "url"), "sqlite:///%s" % (tmp_path / "chips.db")),
        (("auth", "api_tokens"), ["tok"]),
        (("categories",), ["DAQ", "Tracker"]),
    ])
    storage = Storage(cfg["database"]["url"])
    app = create_app(cfg, storage)
    app.config["TESTING"] = True
    client = app.test_client()
    client.post("/api/events", json=make_event(category="Tracker"),
               headers={"Authorization": "Bearer tok"})

    resp = client.get("/")
    assert resp.status_code == 200
    assert b"Tracker" in resp.data
    assert b"DAQ" in resp.data

    filtered = client.get("/?category=Tracker")
    assert filtered.status_code == 200
    assert b"DTC link down" in filtered.data

    filtered_out = client.get("/?category=DAQ")
    assert b"DTC link down" not in filtered_out.data


def test_filter_management_via_web(client, app):
    client.post("/destinations", data={"name": "slackdest", "type": "slack",
                                       "webhook_url": "https://x"})
    client.post("/filters", data={"name": "webrule",
                                  "min_severity": "error",
                                  "source_pattern": "dtc-*",
                                  "category_pattern": "Trigger",
                                  "destinations": ["slackdest"]})
    storage = app.config["NOTIFY_STORAGE"]
    rules = storage.list_filters()
    assert rules[0]["name"] == "webrule"
    assert rules[0]["destinations"] == ["slackdest"]
    assert rules[0]["category_pattern"] == "Trigger"
