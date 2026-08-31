"""The enrollment URL follows the way the request arrived.

The same server is reached at notify.andrewnorman.org through the AWS tunnel,
at mu2edaq-pager.fnal.gov through the OKD route, and at
kaon.andrewnorman.org:8095 directly. A QR code carrying a configured hostname
is wrong in two of those three cases, so the base URL is derived per request.
"""

import json

import pytest

from mu2edaq_notify.server import auth
from mu2edaq_notify.server.app import (create_app, enrollment_payload,
                                       host_is_trusted, host_matches,
                                       public_base_url, split_host_port,
                                       valid_public_host)
from mu2edaq_notify.server.config import load_config
from mu2edaq_notify.server.storage import Storage

OKD = "https://mu2edaq-pager.fnal.gov"


# ------------------------------------------------------------ pure resolution

def test_request_host_wins_over_configured_base_url():
    cfg = {"base_url": OKD}
    assert public_base_url(cfg, host="notify.andrewnorman.org",
                           scheme="https") == "https://notify.andrewnorman.org"


def test_forwarded_headers_win_over_the_host_header():
    # A hop that rewrites Host still reports the client-facing name here.
    cfg = {"base_url": OKD}
    assert public_base_url(cfg, host="127.0.0.1:18095", scheme="http",
                           forwarded_host="notify.andrewnorman.org",
                           forwarded_proto="https") \
        == "https://notify.andrewnorman.org"


def test_leftmost_forwarded_value_is_the_client_facing_one():
    # Two proxies in front (OKD router, then the in-cluster Caddy): each
    # appends, so the first entry is the name the phone used.
    cfg = {}
    assert public_base_url(
        cfg, host="10.0.0.5:8095", scheme="http",
        forwarded_host="mu2edaq-pager.fnal.gov, caddy.svc.cluster.local",
        forwarded_proto="https, http") == "https://mu2edaq-pager.fnal.gov"


def test_direct_access_keeps_its_port():
    cfg = {"base_url": OKD}
    assert public_base_url(cfg, host="kaon.andrewnorman.org:8095",
                           scheme="https") \
        == "https://kaon.andrewnorman.org:8095"


@pytest.mark.parametrize("scheme,host,expected", [
    ("https", "notify.andrewnorman.org:443", "https://notify.andrewnorman.org"),
    ("http", "notify.andrewnorman.org:80", "http://notify.andrewnorman.org"),
    ("https", "notify.andrewnorman.org:8443",
     "https://notify.andrewnorman.org:8443"),
])
def test_default_ports_are_dropped(scheme, host, expected):
    assert public_base_url({}, host=host, scheme=scheme) == expected


def test_dynamic_resolution_can_be_turned_off():
    cfg = {"base_url": OKD, "dynamic_base_url": False}
    assert public_base_url(cfg, host="notify.andrewnorman.org",
                           scheme="https") == OKD


def test_no_config_and_no_dynamic_falls_back_to_url_root():
    cfg = {"base_url": "", "dynamic_base_url": False}
    assert public_base_url(cfg, host="anything", scheme="http",
                           url_root="http://127.0.0.1:8095/") \
        == "http://127.0.0.1:8095"


def test_untrusted_host_falls_back_to_the_configured_url():
    cfg = {"base_url": OKD, "trusted_hosts": ["notify.andrewnorman.org",
                                              "*.fnal.gov"]}
    assert public_base_url(cfg, host="evil.example.com", scheme="https") == OKD


@pytest.mark.parametrize("host", ["mu2edaq-pager.fnal.gov",
                                  "notify.andrewnorman.org",
                                  "notify.andrewnorman.org:8095"])
def test_trusted_hosts_admit_exact_and_wildcard_matches(host):
    cfg = {"base_url": OKD, "trusted_hosts": ["notify.andrewnorman.org",
                                              "*.fnal.gov"]}
    assert host in public_base_url(cfg, host=host, scheme="https")


def test_wildcard_does_not_match_the_bare_suffix():
    assert host_matches("sub.fnal.gov", "*.fnal.gov")
    assert not host_matches("fnal.gov", "*.fnal.gov")
    assert not host_matches("notfnal.gov", "*.fnal.gov")


def test_empty_trusted_hosts_trusts_the_request():
    # This is the default, and it is what lets a new proxy work with no
    # configuration change.
    assert host_is_trusted("anything.example", [])


@pytest.mark.parametrize("host", [
    'evil"host.example',                      # would break out of JSON
    "host with spaces",
    "host/path",
    "javascript:alert(1)",
    "",
    "host:notaport",
    "host:99999",
])
def test_malformed_hosts_are_rejected(host):
    assert not valid_public_host(host)


@pytest.mark.parametrize("host", [
    "notify.andrewnorman.org",
    "kaon.andrewnorman.org:8095",
    "localhost",
    "[::1]:8095",
    "[2001:db8::1]",
])
def test_well_formed_hosts_are_accepted(host):
    assert valid_public_host(host)


def test_malformed_host_falls_back_rather_than_being_reflected():
    cfg = {"base_url": OKD}
    assert public_base_url(cfg, host='evil"host.example', scheme="https") == OKD


@pytest.mark.parametrize("authority,expected", [
    ("host", ("host", "")),
    ("host:8095", ("host", "8095")),
    ("[::1]", ("[::1]", "")),
    ("[::1]:8095", ("[::1]", "8095")),
])
def test_split_host_port(authority, expected):
    assert split_host_port(authority) == expected


def test_enrollment_payload_is_json_not_string_interpolation():
    payload = enrollment_payload('https://host/"x', "tok\"en")
    parsed = json.loads(payload)          # would raise on naive interpolation
    assert parsed["server_url"] == 'https://host/"x'
    assert parsed["enrollment_token"] == 'tok"en'
    assert parsed["type"] == "mu2edaq-notify-config"


# ------------------------------------------------------------- through Flask

@pytest.fixture
def url_app(tmp_path):
    """An app whose configured base_url is the OKD one, as in production."""
    def build(**server_overrides):
        overrides = [
            (("database", "url"), "sqlite:///%s" % (tmp_path / "url.db")),
            (("server", "base_url"), OKD),
        ]
        for key, value in server_overrides.items():
            overrides.append((("server", key), value))
        cfg = load_config(config_file=None, environ={}, overrides=overrides)
        app = create_app(cfg, Storage(cfg["database"]["url"]))
        app.config["TESTING"] = True
        return cfg, app
    return build


def autoconfig_server_url(app, cfg, **kwargs):
    token = auth.make_enrollment_token(cfg)
    with app.test_client() as client:
        resp = client.get("/api/autoconfig/%s" % token, **kwargs)
        assert resp.status_code == 200, resp.data
        return resp.get_json()["server_url"]


def test_autoconfig_reports_the_host_the_phone_used(url_app):
    cfg, app = url_app()
    assert autoconfig_server_url(
        app, cfg, headers={"Host": "notify.andrewnorman.org"},
        base_url="https://notify.andrewnorman.org") \
        == "https://notify.andrewnorman.org"


def test_autoconfig_honours_the_proxy_headers(url_app):
    cfg, app = url_app()
    assert autoconfig_server_url(
        app, cfg,
        headers={"X-Forwarded-Host": "notify.andrewnorman.org",
                 "X-Forwarded-Proto": "https"}) \
        == "https://notify.andrewnorman.org"


def test_autoconfig_falls_back_when_the_host_is_untrusted(url_app):
    cfg, app = url_app(trusted_hosts=["*.fnal.gov"])
    assert autoconfig_server_url(
        app, cfg, headers={"X-Forwarded-Host": "attacker.example",
                           "X-Forwarded-Proto": "https"}) == OKD


def test_registration_response_carries_the_same_url(url_app):
    cfg, app = url_app()
    token = auth.make_enrollment_token(cfg)
    with app.test_client() as client:
        resp = client.post("/api/devices/register",
                           json={"enrollment_token": token,
                                 "name": "test-iPhone",
                                 "apns_token": "a" * 64},
                           headers={"X-Forwarded-Host":
                                    "notify.andrewnorman.org",
                                    "X-Forwarded-Proto": "https"})
    assert resp.status_code == 201, resp.data
    assert resp.get_json()["server_url"] == "https://notify.andrewnorman.org"


def test_enrollment_page_and_qr_use_the_request_host(url_app):
    cfg, app = url_app()
    with app.test_client() as client:
        resp = client.post("/devices/enroll",
                           headers={"X-Forwarded-Host":
                                    "notify.andrewnorman.org",
                                    "X-Forwarded-Proto": "https"})
        assert resp.status_code == 200, resp.data
        body = resp.get_data(as_text=True)
        assert "https://notify.andrewnorman.org" in body
        assert OKD not in body

        qr = client.get("/devices/qr.png?token=%s"
                        % auth.make_enrollment_token(cfg),
                        headers={"X-Forwarded-Host": "notify.andrewnorman.org",
                                 "X-Forwarded-Proto": "https"})
        assert qr.status_code == 200
        assert qr.mimetype == "image/png"


def test_configured_url_still_wins_when_dynamic_is_off(url_app):
    cfg, app = url_app(dynamic_base_url=False)
    assert autoconfig_server_url(
        app, cfg, headers={"X-Forwarded-Host": "notify.andrewnorman.org",
                           "X-Forwarded-Proto": "https"}) == OKD
