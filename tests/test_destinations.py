from mu2edaq_notify.events import normalize_event
from mu2edaq_notify.server import destinations as dest_mod
from mu2edaq_notify.server.destinations import send_discord, send_slack
from conftest import make_event


class _Response:
    status_code = 200
    text = ""


def test_slack_payload_includes_category(monkeypatch):
    captured = {}

    def fake_post(url, json, timeout):
        captured["url"] = url
        captured["json"] = json
        return _Response()

    monkeypatch.setattr(dest_mod.httpx, "post", fake_post)
    event = normalize_event(make_event(category="Tracker"))
    status, _ = send_slack("https://hooks.slack.example/x", event)

    assert status == "sent"
    assert "[ERROR/Tracker]" in captured["json"]["text"]
    fields = {f["title"]: f["value"]
              for f in captured["json"]["attachments"][0]["fields"]}
    assert fields["Category"] == "Tracker"


def test_slack_payload_omits_category_field_when_uncategorized(monkeypatch):
    captured = {}

    def fake_post(url, json, timeout):
        captured["json"] = json
        return _Response()

    monkeypatch.setattr(dest_mod.httpx, "post", fake_post)
    event = normalize_event(make_event(category=""))
    send_slack("https://hooks.slack.example/x", event)

    fields = [f["title"] for f in captured["json"]["attachments"][0]["fields"]]
    assert "Category" not in fields
    assert "[ERROR]" in captured["json"]["text"]
    assert "[ERROR/" not in captured["json"]["text"]


def test_discord_payload_includes_category(monkeypatch):
    captured = {}

    def fake_post(url, json, timeout):
        captured["json"] = json
        return _Response()

    monkeypatch.setattr(dest_mod.httpx, "post", fake_post)
    event = normalize_event(make_event(category="Calorimeter"))
    status, _ = send_discord("https://discord.example/webhook", event)

    assert status == "sent"
    embed = captured["json"]["embeds"][0]
    assert "[ERROR/Calorimeter]" in embed["title"]
    fields = {f["name"]: f["value"] for f in embed["fields"]}
    assert fields["Category"] == "Calorimeter"
