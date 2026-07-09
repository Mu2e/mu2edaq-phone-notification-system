"""Server configuration.

Precedence: command line > environment (MU2EDAQ_NOTIFY_*) > YAML config
file > built-in defaults.
"""
from __future__ import annotations

import copy
import os
import secrets

import yaml

ENV_CONFIG = "MU2EDAQ_NOTIFY_CONFIG"

DEFAULTS = {
    "server": {
        "host": "0.0.0.0",
        "port": 8095,
        "base_url": "",
        "secret_key": "",
        "tls": {
            "enabled": False,
            "cert_file": "",
            "key_file": "",
            "adhoc": False,
        },
    },
    "database": {
        "url": "sqlite:///data/notify.db",
        "retention_days": 30,
    },
    "auth": {
        "api_tokens": [],
        "api_tokens_file": "",
        "enrollment_secret": "",
        "enrollment_ttl_minutes": 30,
        "oidc": {
            "enabled": False,
            "issuer": "https://pingprod.fnal.gov",
            "client_id": "",
            "client_secret": "",
            "allowed_users": [],
        },
    },
    "apns": {
        "enabled": False,
        "key_file": "config/apns_key.p8",
        "key_id": "",
        "team_id": "",
        "bundle_id": "gov.fnal.mu2e.Mu2eNotify",
        "sandbox": True,
    },
    "zmq": {
        "enabled": False,
        "connect": [],
        "bind": "tcp://0.0.0.0:8096",
        "default_severity": "warning",
        "default_source": "zmq",
    },
    "discovery": {
        "enabled": True,
        "name": "Mu2e DAQ Notification Server",
        "app": "notify",
        # host/port/scheme: empty means "advertise the local server itself"
        # (host defaults to this machine's FQDN, port to server.port,
        # scheme to http/https matching server.tls.enabled). This is what
        # on-network DAQ publishers should reach directly.
        "host": "",
        "port": 0,
        "scheme": "",
        # Advertised in the ANNOUNCE meta as "fallback_url". Publishers
        # try the local host/port/scheme above first and only fall back
        # to this address (typically the public reverse-proxy URL) when
        # the local one is unreachable.
        "fallback_url": "",
    },
    "dispatch": {
        "rate_limit_seconds": 60,
    },
    "seed": {
        "destinations": [],
        "filters": [],
    },
}

# Environment variable -> config path. Values are parsed with YAML so
# "true", "8095", and "[a, b]" all do the right thing.
ENV_MAP = {
    "MU2EDAQ_NOTIFY_HOST": ("server", "host"),
    "MU2EDAQ_NOTIFY_PORT": ("server", "port"),
    "MU2EDAQ_NOTIFY_BASE_URL": ("server", "base_url"),
    "MU2EDAQ_NOTIFY_TLS_ENABLED": ("server", "tls", "enabled"),
    "MU2EDAQ_NOTIFY_TLS_CERT_FILE": ("server", "tls", "cert_file"),
    "MU2EDAQ_NOTIFY_TLS_KEY_FILE": ("server", "tls", "key_file"),
    "MU2EDAQ_NOTIFY_TLS_ADHOC": ("server", "tls", "adhoc"),
    "MU2EDAQ_NOTIFY_DB_URL": ("database", "url"),
    "MU2EDAQ_NOTIFY_API_TOKEN": ("auth", "api_tokens"),
    "MU2EDAQ_NOTIFY_API_TOKENS_FILE": ("auth", "api_tokens_file"),
    "MU2EDAQ_NOTIFY_APNS_ENABLED": ("apns", "enabled"),
    "MU2EDAQ_NOTIFY_ZMQ_ENABLED": ("zmq", "enabled"),
    "MU2EDAQ_NOTIFY_ZMQ_BIND": ("zmq", "bind"),
    "MU2EDAQ_NOTIFY_DISCOVERY_ENABLED": ("discovery", "enabled"),
    "MU2EDAQ_NOTIFY_DISCOVERY_HOST": ("discovery", "host"),
    "MU2EDAQ_NOTIFY_DISCOVERY_PORT": ("discovery", "port"),
    "MU2EDAQ_NOTIFY_DISCOVERY_SCHEME": ("discovery", "scheme"),
    "MU2EDAQ_NOTIFY_DISCOVERY_FALLBACK_URL": ("discovery", "fallback_url"),
}


def _deep_merge(base, override):
    out = copy.deepcopy(base)
    for key, value in (override or {}).items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _deep_merge(out[key], value)
        else:
            out[key] = copy.deepcopy(value)
    return out


def _set_path(cfg, path, value):
    node = cfg
    for key in path[:-1]:
        node = node.setdefault(key, {})
    leaf = path[-1]
    # Single-token env var for a list-valued setting appends, not replaces.
    if isinstance(node.get(leaf), list) and not isinstance(value, list):
        node[leaf] = node[leaf] + [value]
    else:
        node[leaf] = value


def load_config(config_file=None, overrides=None, environ=None):
    """Build the effective configuration dict.

    ``overrides`` is a list of (path_tuple, value) applied last -- the
    command line layer.
    """
    environ = os.environ if environ is None else environ
    cfg = copy.deepcopy(DEFAULTS)

    path = config_file or environ.get(ENV_CONFIG)
    if path and os.path.exists(path):
        with open(path) as fh:
            file_cfg = yaml.safe_load(fh) or {}
        cfg = _deep_merge(cfg, file_cfg)
    cfg["_config_file"] = path or ""

    for env_name, cfg_path in ENV_MAP.items():
        if env_name in environ:
            _set_path(cfg, cfg_path, yaml.safe_load(environ[env_name]))

    for cfg_path, value in overrides or []:
        _set_path(cfg, cfg_path, value)

    token_file = cfg["auth"].get("api_tokens_file")
    if token_file and os.path.exists(token_file):
        with open(token_file) as fh:
            for line in fh:
                token = line.strip()
                if token and not token.startswith("#"):
                    _set_path(cfg, ("auth", "api_tokens"), token)

    for key, generator in (
            (("server", "secret_key"), lambda: secrets.token_hex(32)),
            (("auth", "enrollment_secret"), lambda: secrets.token_hex(32))):
        node = cfg
        for part in key[:-1]:
            node = node[part]
        if not node[key[-1]]:
            node[key[-1]] = generator()

    return cfg
