from mu2edaq_notify.events import normalize_event
from mu2edaq_notify.server.destinations import ApnsSender
from mu2edaq_notify.server import dispatch as dispatch_mod
from mu2edaq_notify.server.dispatch import Dispatcher
from conftest import make_event


def make_dispatcher(storage, cfg):
    d = Dispatcher(storage, cfg)   # not started: tests call _dispatch()
    return d


def stored_error(storage):
    return storage.add_event(normalize_event(make_event()))


def test_slack_and_discord_delivery(storage, cfg, monkeypatch):
    calls = []
    monkeypatch.setattr(dispatch_mod, "send_slack",
                        lambda url, e: calls.append(("slack", url))
                        or ("sent", ""))
    monkeypatch.setattr(dispatch_mod, "send_discord",
                        lambda url, e: calls.append(("discord", url))
                        or ("sent", ""))
    storage.upsert_destination("s", type="slack", webhook_url="https://s")
    storage.upsert_destination("d", type="discord", webhook_url="https://d")
    storage.upsert_filter("all-errors", min_severity="error",
                          destinations=["s", "d"])
    dispatcher = make_dispatcher(storage, cfg)
    event = stored_error(storage)
    dispatcher._dispatch(event)

    assert ("slack", "https://s") in calls
    assert ("discord", "https://d") in calls
    statuses = {x["destination"]: x["status"]
                for x in storage.deliveries_for_event(event["id"])}
    assert statuses == {"s": "sent", "d": "sent"}


def test_apns_log_only_mode(storage, cfg):
    storage.upsert_destination("phones", type="apns")
    storage.upsert_filter("errs", min_severity="error",
                          destinations=["phones"])
    device, _ = storage.register_device("iPhone")
    storage.update_device(device["id"], apns_token="tok",
                          min_severity="debug")
    dispatcher = make_dispatcher(storage, cfg)  # apns.enabled is False
    event = stored_error(storage)
    dispatcher._dispatch(event)

    deliveries = storage.deliveries_for_event(event["id"])
    assert len(deliveries) == 1
    assert deliveries[0]["status"] == "logged"


def test_apns_alert_payload_is_plain_visible_notification(cfg):
    class Response:
        status_code = 200
        headers = {"apns-id": "apns-123"}
        text = ""

    calls = []

    class Client:
        def post(self, path, json, headers):
            calls.append((path, json, headers))
            return Response()

    cfg["apns"].update(enabled=True, key_id="KEYID", team_id="TEAMID",
                       bundle_id="gov.fnal.mu2e.Mu2eNotify")
    sender = ApnsSender(cfg["apns"])
    sender._client = Client()
    sender._key = b"unused"
    sender._token = lambda: "jwt"

    status, detail = sender.send("device-token", normalize_event(make_event()))

    assert status == "sent"
    assert detail == "apns-123"
    path, payload, headers = calls[0]
    assert path == "/3/device/device-token"
    assert headers["apns-push-type"] == "alert"
    assert headers["apns-topic"] == "gov.fnal.mu2e.Mu2eNotify"
    assert payload["aps"]["alert"]["title"] == "[ERROR] DTC link down"
    assert payload["aps"]["sound"] == "default"
    assert "interruption-level" not in payload["aps"]
    assert all(value is not None for value in payload["aps"].values())


def test_no_matching_rule_means_no_delivery(storage, cfg):
    storage.upsert_destination("phones", type="apns")
    storage.upsert_filter("critical-only", min_severity="critical",
                          destinations=["phones"])
    dispatcher = make_dispatcher(storage, cfg)
    event = stored_error(storage)
    dispatcher._dispatch(event)
    assert storage.deliveries_for_event(event["id"]) == []


def test_rate_limiting_suppresses_repeats(storage, cfg):
    storage.upsert_destination("phones", type="apns")
    storage.upsert_filter("errs", min_severity="error",
                          destinations=["phones"])
    cfg["dispatch"]["rate_limit_seconds"] = 3600
    dispatcher = make_dispatcher(storage, cfg)

    first = stored_error(storage)
    second = stored_error(storage)   # identical source/severity/title
    dispatcher._dispatch(first)
    dispatcher._dispatch(second)

    assert storage.deliveries_for_event(first["id"])[0]["status"] == "logged"
    assert (storage.deliveries_for_event(second["id"])[0]["status"]
            == "suppressed")


def test_disabled_destination_skipped(storage, cfg, monkeypatch):
    monkeypatch.setattr(dispatch_mod, "send_slack",
                        lambda url, e: ("sent", ""))
    storage.upsert_destination("s", type="slack", webhook_url="https://s",
                               enabled=False)
    storage.upsert_filter("errs", min_severity="error", destinations=["s"])
    dispatcher = make_dispatcher(storage, cfg)
    event = stored_error(storage)
    dispatcher._dispatch(event)
    assert storage.deliveries_for_event(event["id"]) == []
