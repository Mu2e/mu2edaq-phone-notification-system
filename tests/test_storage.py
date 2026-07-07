from datetime import datetime, timedelta, timezone

from mu2edaq_notify.events import normalize_event
from conftest import make_event


def test_event_roundtrip(storage):
    stored = storage.add_event(normalize_event(make_event()))
    assert stored["id"] == 1
    fetched = storage.get_event(1)
    assert fetched["title"] == "DTC link down"
    assert fetched["meta"] == {"run": "107001"}


def test_list_events_filtering(storage):
    storage.add_event(normalize_event(make_event(severity="error")))
    storage.add_event(normalize_event(make_event(severity="warning",
                                                 source="cfo")))
    assert len(storage.list_events()) == 2
    assert len(storage.list_events(severity="error")) == 1
    assert len(storage.list_events(source="cfo")) == 1
    assert storage.list_events()[0]["id"] == 2  # newest first


def test_event_counts(storage):
    storage.add_event(normalize_event(make_event(severity="error")))
    storage.add_event(normalize_event(make_event(severity="error")))
    storage.add_event(normalize_event(make_event(severity="info")))
    assert storage.event_counts() == {"error": 2, "info": 1}


def test_device_registration_and_token_lookup(storage):
    device, token = storage.register_device("Andrew's iPhone", "apns123")
    assert token.startswith("mu2edev-")
    found = storage.device_by_token(token)
    assert found["id"] == device["id"]
    assert storage.device_by_token("wrong-token") is None


def test_apns_targets_respect_min_severity_and_enabled(storage):
    d1, _ = storage.register_device("errors-only")
    storage.update_device(d1["id"], apns_token="tok1",
                          min_severity="error")
    d2, _ = storage.register_device("everything")
    storage.update_device(d2["id"], apns_token="tok2",
                          min_severity="debug")
    d3, _ = storage.register_device("disabled")
    storage.update_device(d3["id"], apns_token="tok3", enabled=False)

    warning_targets = {t["name"] for t in storage.apns_targets("warning")}
    assert warning_targets == {"everything"}
    error_targets = {t["name"] for t in storage.apns_targets("error")}
    assert error_targets == {"errors-only", "everything"}


def test_filter_and_destination_crud(storage):
    storage.upsert_destination("phones", type="apns")
    storage.upsert_filter("errs", min_severity="error",
                          destinations=["phones"])
    assert storage.list_filters()[0]["destinations"] == ["phones"]
    storage.upsert_filter("errs", enabled=False)
    assert storage.list_filters()[0]["enabled"] is False
    assert storage.delete_filter(storage.list_filters()[0]["id"])
    assert storage.list_filters() == []


def test_seed_only_when_empty(storage):
    seed = {"destinations": [{"name": "phones", "type": "apns"}],
            "filters": [{"name": "f", "destinations": ["phones"]}]}
    storage.seed(seed)
    assert len(storage.list_destinations()) == 1
    # A second seed with different content must not duplicate or override.
    storage.seed({"destinations": [{"name": "other", "type": "slack"}],
                  "filters": []})
    assert len(storage.list_destinations()) == 1


def test_prune_events(storage):
    stored = storage.add_event(normalize_event(make_event()))
    storage.add_delivery(stored["id"], "phones", "dev", "sent")
    # Age the event artificially.
    from mu2edaq_notify.server.storage import Event
    with storage.session() as s:
        row = s.get(Event, stored["id"])
        row.received_at = (datetime.now(timezone.utc).replace(tzinfo=None)
                           - timedelta(days=45))
        s.commit()
    assert storage.prune_events(30) == 1
    assert storage.get_event(stored["id"]) is None
    assert storage.prune_events(0) == 0
