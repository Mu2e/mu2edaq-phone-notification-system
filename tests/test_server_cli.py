from mu2edaq_notify.server.cli import discovery_meta


def test_discovery_meta_includes_fallback_url():
    cfg = {"discovery": {"fallback_url": "https://notify.andrewnorman.org"}}
    assert discovery_meta(cfg) == {
        "fallback_url": "https://notify.andrewnorman.org"}


def test_discovery_meta_none_when_no_fallback_configured():
    assert discovery_meta({"discovery": {"fallback_url": ""}}) is None
    assert discovery_meta({"discovery": {}}) is None
