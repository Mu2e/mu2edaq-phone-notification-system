from mu2edaq_notify.server.filters import match_destinations, rule_matches

EVENT = {
    "source": "dtc-monitor", "host": "mu2edaq09", "severity": "error",
    "category": "Trigger",
    "title": "DTC link down", "message": "ROC link 3 lost lock",
}


def rule(**overrides):
    base = {"name": "r", "enabled": True, "min_severity": "warning",
            "source_pattern": "*", "host_pattern": "*",
            "category_pattern": "*",
            "message_regex": "", "destinations": ["phones"]}
    base.update(overrides)
    return base


def test_matches_by_severity_threshold():
    assert rule_matches(rule(min_severity="error"), EVENT)
    assert rule_matches(rule(min_severity="warning"), EVENT)
    assert not rule_matches(rule(min_severity="critical"), EVENT)


def test_disabled_rule_never_matches():
    assert not rule_matches(rule(enabled=False), EVENT)


def test_source_and_host_globs():
    assert rule_matches(rule(source_pattern="dtc-*"), EVENT)
    assert not rule_matches(rule(source_pattern="cfo-*"), EVENT)
    assert rule_matches(rule(host_pattern="mu2edaq0?"), EVENT)
    assert not rule_matches(rule(host_pattern="mu2edaq1?"), EVENT)


def test_category_glob():
    assert rule_matches(rule(category_pattern="Trigger"), EVENT)
    assert rule_matches(rule(category_pattern="Trig*"), EVENT)
    assert not rule_matches(rule(category_pattern="Tracker"), EVENT)
    assert rule_matches(rule(category_pattern="*"), EVENT)


def test_category_pattern_matches_uncategorized_events():
    uncategorized = dict(EVENT, category="")
    assert rule_matches(rule(category_pattern="*"), uncategorized)
    assert not rule_matches(rule(category_pattern="Trigger"), uncategorized)


def test_message_regex():
    assert rule_matches(rule(message_regex=r"link \d"), EVENT)
    assert not rule_matches(rule(message_regex=r"fire"), EVENT)


def test_bad_regex_does_not_match_or_raise():
    assert not rule_matches(rule(message_regex="("), EVENT)


def test_match_destinations_dedupes():
    rules = [rule(destinations=["phones", "slack"]),
             rule(name="r2", destinations=["slack", "discord"]),
             rule(name="off", enabled=False, destinations=["nope"])]
    assert match_destinations(rules, EVENT) == ["phones", "slack", "discord"]
