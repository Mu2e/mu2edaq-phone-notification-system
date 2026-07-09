from mu2edaq_notify.server.config import load_config


def test_defaults():
    cfg = load_config(environ={})
    assert cfg["server"]["port"] == 8095
    assert cfg["server"]["tls"]["enabled"] is False
    assert cfg["database"]["url"].startswith("sqlite:///")
    assert cfg["server"]["secret_key"]          # auto-generated
    assert cfg["auth"]["enrollment_secret"]     # auto-generated


def test_yaml_file_overrides_defaults(tmp_path):
    path = tmp_path / "cfg.yaml"
    path.write_text("server:\n  port: 9000\nzmq:\n  enabled: true\n")
    cfg = load_config(config_file=str(path), environ={})
    assert cfg["server"]["port"] == 9000
    assert cfg["zmq"]["enabled"] is True
    assert cfg["server"]["host"] == "0.0.0.0"   # untouched default


def test_env_overrides_file(tmp_path):
    path = tmp_path / "cfg.yaml"
    path.write_text("server:\n  port: 9000\n")
    cfg = load_config(config_file=str(path),
                      environ={"MU2EDAQ_NOTIFY_PORT": "9100"})
    assert cfg["server"]["port"] == 9100


def test_cli_overrides_env(tmp_path):
    cfg = load_config(environ={"MU2EDAQ_NOTIFY_PORT": "9100"},
                      overrides=[(("server", "port"), 9200)])
    assert cfg["server"]["port"] == 9200


def test_env_token_appends_to_list(tmp_path):
    path = tmp_path / "cfg.yaml"
    path.write_text("auth:\n  api_tokens: [from-file]\n")
    cfg = load_config(config_file=str(path),
                      environ={"MU2EDAQ_NOTIFY_API_TOKEN": "from-env"})
    assert cfg["auth"]["api_tokens"] == ["from-file", "from-env"]


def test_api_tokens_file_appends_to_list(tmp_path):
    token_file = tmp_path / "tokens"
    token_file.write_text("# comment\nfrom-token-file\n\n")
    path = tmp_path / "cfg.yaml"
    path.write_text("auth:\n"
                    "  api_tokens: [from-yaml]\n"
                    "  api_tokens_file: \"%s\"\n" % token_file)
    cfg = load_config(config_file=str(path), environ={})
    assert cfg["auth"]["api_tokens"] == ["from-yaml", "from-token-file"]


def test_config_file_from_environment(tmp_path):
    path = tmp_path / "cfg.yaml"
    path.write_text("server:\n  port: 9300\n")
    cfg = load_config(environ={"MU2EDAQ_NOTIFY_CONFIG": str(path)})
    assert cfg["server"]["port"] == 9300


def test_tls_environment_overrides():
    cfg = load_config(environ={
        "MU2EDAQ_NOTIFY_TLS_ENABLED": "true",
        "MU2EDAQ_NOTIFY_TLS_CERT_FILE": "cert.pem",
        "MU2EDAQ_NOTIFY_TLS_KEY_FILE": "key.pem",
    })
    assert cfg["server"]["tls"]["enabled"] is True
    assert cfg["server"]["tls"]["cert_file"] == "cert.pem"
    assert cfg["server"]["tls"]["key_file"] == "key.pem"


def test_discovery_advertisement_overrides():
    cfg = load_config(environ={
        "MU2EDAQ_NOTIFY_DISCOVERY_HOST": "notify.example",
        "MU2EDAQ_NOTIFY_DISCOVERY_PORT": "443",
        "MU2EDAQ_NOTIFY_DISCOVERY_SCHEME": "https",
    })
    assert cfg["discovery"]["host"] == "notify.example"
    assert cfg["discovery"]["port"] == 443
    assert cfg["discovery"]["scheme"] == "https"
